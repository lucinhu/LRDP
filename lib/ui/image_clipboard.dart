import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../rdp/clipboard_picture.dart';

Uint8List _dib((int, int, Uint8List) image) =>
    ClipboardPicture.encodeDib(image.$1, image.$2, image.$3);

class ImageClipboard {
  static const channel = MethodChannel('dev.lrdp/clipboard_image');
  static Future<ClipboardPicture?> read() async {
    final data = await channel.invokeMapMethod<String, dynamic>('read');
    if (data == null) return null;
    return ClipboardPicture.decode(
      data['bytes'] as Uint8List,
      kind: data['kind'] as int,
      width: data['width'] as int?,
      height: data['height'] as int?,
    );
  }

  static Future<bool> write(
    ClipboardPicture image, {
    bool Function()? isCurrent,
  }) async {
    final dib = await compute(_dib, (image.width, image.height, image.rgba));
    if (isCurrent != null && !isCurrent()) return false;
    final prepared = await channel.invokeMethod<Object?>('write', {
      'png': image.png,
      'dib': dib,
      'rgba': image.rgba,
      'width': image.width,
      'height': image.height,
    });
    // Android prepares its content URI off-thread. Recheck the originating
    // session before the short, synchronous ClipboardManager publication.
    if (prepared is Map && prepared['token'] is String) {
      final token = {'token': prepared['token']};
      if (isCurrent != null && !isCurrent()) {
        await channel.invokeMethod<void>('discard', token);
        return false;
      }
      await channel.invokeMethod<void>('publish', token);
    }
    return true;
  }
}
