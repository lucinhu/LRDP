import 'dart:typed_data';
import 'dart:ui' as ui;

/// Owned, bounded clipboard pixels. PNG keeps alpha; the DIB fallback is an
/// opaque bitmap with transparency composited onto white for older RDP peers.
class ClipboardPicture {
  ClipboardPicture._(this.width, this.height, this.png, this.rgba);
  static const maxBytes = 16 * 1024 * 1024;
  static const maxPixels = 4 * 1024 * 1024;
  final int width, height;
  final Uint8List png, rgba;
  static void checkSize(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        width * height > maxPixels) {
      throw const FormatException('图片最多 4096×4096，且总像素不超过 4194304');
    }
  }

  static Future<ClipboardPicture> decode(
    Uint8List bytes, {
    int kind = 1,
    int? width,
    int? height,
  }) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('图片数据最大 16 MiB');
    }
    if (kind == 2) {
      final bitmap = decodeDib(bytes);
      return decode(bitmap.$3, kind: 3, width: bitmap.$1, height: bitmap.$2);
    }
    if (kind != 1 && kind != 3) throw const FormatException('不支持的图片格式');
    if (kind == 3) {
      checkSize(width ?? 0, height ?? 0);
      if (bytes.length != width! * height! * 4) {
        throw const FormatException('图片像素数据不完整');
      }
    }
    var encoded = bytes;
    if (kind == 3) {
      // Flutter's raw descriptor takes premultiplied pixels; clipboard/DIB
      // values and the public rgba member use straight alpha.
      encoded = Uint8List.fromList(bytes);
      for (var i = 0; i < encoded.length; i += 4) {
        for (var c = 0; c < 3; c++) {
          encoded[i + c] = (encoded[i + c] * encoded[i + 3] + 127) ~/ 255;
        }
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = kind == 3
          ? ui.ImageDescriptor.raw(
              buffer,
              width: width!,
              height: height!,
              pixelFormat: ui.PixelFormat.rgba8888,
            )
          : await ui.ImageDescriptor.encoded(buffer);
      checkSize(descriptor.width, descriptor.height);
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      final pixels = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (pixels == null || png == null || png.lengthInBytes > maxBytes) {
        throw const FormatException('图片数据最大 16 MiB');
      }
      return ClipboardPicture._(
        image.width,
        image.height,
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Uint8List toDib() => encodeDib(width, height, rgba);

  static Uint8List encodeDib(int width, int height, Uint8List rgba) {
    checkSize(width, height);
    if (rgba.length != width * height * 4) {
      throw const FormatException('图片像素数据不完整');
    }
    final stride = (width * 3 + 3) ~/ 4 * 4;
    final out = Uint8List(40 + stride * height);
    final header = ByteData.sublistView(out);
    header.setUint32(0, 40, Endian.little);
    header.setInt32(4, width, Endian.little);
    header.setInt32(8, height, Endian.little);
    header.setUint16(12, 1, Endian.little);
    header.setUint16(14, 24, Endian.little);
    header.setUint32(20, stride * height, Endian.little);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final src = (y * width + x) * 4;
        final dst = 40 + (height - 1 - y) * stride + x * 3;
        final alpha = rgba[src + 3];
        for (var c = 0; c < 3; c++) {
          out[dst + c] =
              (rgba[src + 2 - c] * alpha + 255 * (255 - alpha) + 127) ~/ 255;
        }
      }
    }
    return out;
  }

  static (int, int, Uint8List) decodeDib(Uint8List bytes) {
    const invalid = FormatException('不支持或不完整的远程位图');
    if (bytes.length < 40 || bytes.length > maxBytes) throw invalid;
    final d = ByteData.sublistView(bytes);
    final header = d.getUint32(0, Endian.little);
    if (!{40, 108, 124}.contains(header) || bytes.length < header) {
      throw invalid;
    }
    final width = d.getInt32(4, Endian.little);
    final signedHeight = d.getInt32(8, Endian.little);
    final height = signedHeight.abs();
    checkSize(width, height);
    final bits = d.getUint16(14, Endian.little);
    final compression = d.getUint32(16, Endian.little);
    if (d.getUint16(12, Endian.little) != 1 ||
        !{24, 32}.contains(bits) ||
        d.getUint32(32, Endian.little) != 0 ||
        !{0, 3}.contains(compression)) {
      throw invalid;
    }
    var offset = header;
    var alpha = false;
    if (compression == 3) {
      if (bits != 32 ||
          bytes.length < 52 ||
          d.getUint32(40, Endian.little) != 0xff0000 ||
          d.getUint32(44, Endian.little) != 0xff00 ||
          d.getUint32(48, Endian.little) != 0xff) {
        throw invalid;
      }
      if (header == 40) {
        offset += 12;
      } else {
        final mask = d.getUint32(52, Endian.little);
        if (mask != 0 && mask != 0xff000000) throw invalid;
        alpha = mask != 0;
      }
    }
    if (header == 124 &&
        (d.getUint32(112, Endian.little) != 0 ||
            d.getUint32(116, Endian.little) != 0)) {
      throw invalid;
    }
    final stride = (width * bits + 31) ~/ 32 * 4;
    if (offset + stride * height > bytes.length) throw invalid;
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      final row = offset + (signedHeight < 0 ? y : height - 1 - y) * stride;
      for (var x = 0; x < width; x++) {
        final src = row + x * (bits ~/ 8), dst = (y * width + x) * 4;
        out[dst] = bytes[src + 2];
        out[dst + 1] = bytes[src + 1];
        out[dst + 2] = bytes[src];
        out[dst + 3] = alpha ? bytes[src + 3] : 255;
      }
    }
    return (width, height, out);
  }
}
