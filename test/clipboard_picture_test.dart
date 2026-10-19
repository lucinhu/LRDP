import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/clipboard_picture.dart';
import 'package:lrdp/ui/image_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Independent 3x2 bottom-up BGR golden. Each row has three padding bytes.
  final dib = Uint8List.fromList([
    40,
    0,
    0,
    0,
    3,
    0,
    0,
    0,
    2,
    0,
    0,
    0,
    1,
    0,
    24,
    0,
    0,
    0,
    0,
    0,
    24,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    255,
    255,
    255,
    0,
    0,
    0,
    255,
    255,
    0,
    0,
    0,
    0,
    0,
    0,
    255,
    0,
    255,
    0,
    255,
    0,
    0,
    0,
    0,
    0,
  ]);
  final rgba = Uint8List.fromList([
    255,
    0,
    0,
    255,
    0,
    255,
    0,
    255,
    0,
    0,
    255,
    255,
    255,
    255,
    255,
    255,
    0,
    0,
    0,
    255,
    0,
    255,
    255,
    255,
  ]);
  test('DIB golden preserves orientation, BGR colors and row padding', () {
    final decoded = ClipboardPicture.decodeDib(dib);
    expect((decoded.$1, decoded.$2), (3, 2));
    expect(decoded.$3, rgba);
    expect(ClipboardPicture.encodeDib(3, 2, rgba), dib);
    final topDown = Uint8List.fromList(dib);
    ByteData.sublistView(topDown).setInt32(8, -2, Endian.little);
    topDown.setRange(40, 52, dib.sublist(52));
    topDown.setRange(52, 64, dib.sublist(40, 52));
    expect(ClipboardPicture.decodeDib(topDown).$3, rgba);
  });
  test(
    'DIB flattens transparency onto white and treats BI_RGB alpha as unused',
    () {
      final alpha = ClipboardPicture.encodeDib(
        1,
        1,
        Uint8List.fromList([255, 0, 0, 128]),
      );
      expect(alpha.sublist(40), [127, 127, 255, 0]);
      final rgb32 = Uint8List(44);
      rgb32.setRange(0, 40, dib.sublist(0, 40));
      final header = ByteData.sublistView(rgb32);
      header.setInt32(4, 1, Endian.little);
      header.setInt32(8, -1, Endian.little);
      header.setUint16(14, 32, Endian.little);
      rgb32.setRange(40, 44, [3, 2, 1, 0]);
      expect(ClipboardPicture.decodeDib(rgb32).$3, [1, 2, 3, 255]);
    },
  );
  test(
    'V5 bitfields preserve alpha; invalid profiles, masks and sizes fail',
    () {
      final v5 = Uint8List(128);
      v5.setRange(0, 40, dib.sublist(0, 40));
      final h = ByteData.sublistView(v5);
      h.setUint32(0, 124, Endian.little);
      h.setInt32(4, 1, Endian.little);
      h.setInt32(8, 1, Endian.little);
      h.setUint16(14, 32, Endian.little);
      h.setUint32(16, 3, Endian.little);
      for (final (offset, mask) in [
        (40, 0xff0000),
        (44, 0xff00),
        (48, 0xff),
        (52, 0xff000000),
      ]) {
        h.setUint32(offset, mask, Endian.little);
      }
      v5.setRange(124, 128, [20, 40, 60, 128]);
      expect(ClipboardPicture.decodeDib(v5).$3, [60, 40, 20, 128]);
      h.setUint32(112, 124, Endian.little);
      expect(() => ClipboardPicture.decodeDib(v5), throwsFormatException);
      h.setUint32(112, 0, Endian.little);
      h.setUint32(48, 15, Endian.little);
      expect(() => ClipboardPicture.decodeDib(v5), throwsFormatException);
      for (var length = 0; length < 64; length++) {
        expect(
          () => ClipboardPicture.decodeDib(dib.sublist(0, length)),
          throwsFormatException,
        );
      }
      for (final size in [
        (0, 1),
        (-1, 1),
        (4097, 1),
        (4096, 4096),
        (1, 2147483648),
      ]) {
        expect(
          () => ClipboardPicture.checkSize(size.$1, size.$2),
          throwsFormatException,
        );
      }
      expect(
        () => ClipboardPicture.encodeDib(3, 2, Uint8List(1)),
        throwsFormatException,
      );
    },
  );
  test(
    'bounded PNG roundtrip preserves visible straight alpha pixels',
    () async {
      final picture = await ClipboardPicture.decode(
        rgba,
        kind: 3,
        width: 3,
        height: 2,
      );
      expect(picture.rgba, rgba);
      final decoded = await ClipboardPicture.decode(picture.png);
      expect(decoded.rgba, rgba);
      final translucent = await ClipboardPicture.decode(
        Uint8List.fromList([255, 0, 0, 128]),
        kind: 3,
        width: 1,
        height: 1,
      );
      expect(translucent.rgba, [255, 0, 0, 128]);
      await expectLater(
        ClipboardPicture.decode(Uint8List(1)),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        ClipboardPicture.decode(
          Uint8List(1),
          kind: 3,
          width: 4096,
          height: 4096,
        ),
        throwsFormatException,
      );
      await expectLater(
        ClipboardPicture.decode(Uint8List(ClipboardPicture.maxBytes + 1)),
        throwsFormatException,
      );
    },
  );
  test(
    'OS image bridge handles absence, DIB reads and complete native writes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Object? native;
      messenger.setMockMethodCallHandler(ImageClipboard.channel, (call) async {
        if (call.method == 'read') return native;
        final args = call.arguments as Map;
        expect(args['width'], 3);
        expect(args['height'], 2);
        expect(args['rgba'], rgba);
        expect(args['dib'], dib);
        expect(args['png'], isA<Uint8List>());
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ImageClipboard.channel, null),
      );
      expect(await ImageClipboard.read(), isNull);
      native = {'kind': 2, 'bytes': dib};
      final picture = (await ImageClipboard.read())!;
      await ImageClipboard.write(picture);
      native = {'kind': 2, 'bytes': Uint8List(1)};
      await expectLater(ImageClipboard.read(), throwsFormatException);
    },
  );
  test(
    'Android prepared image is discarded if its session changes before publication',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var active = true;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(ImageClipboard.channel, (call) async {
        methods.add(call.method);
        if (call.method == 'write') {
          active = false;
          return {'token': 'prepared'};
        }
        expect(call.arguments, {'token': 'prepared'});
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ImageClipboard.channel, null),
      );
      final picture = await ClipboardPicture.decode(
        rgba,
        kind: 3,
        width: 3,
        height: 2,
      );
      expect(
        await ImageClipboard.write(picture, isCurrent: () => active),
        false,
      );
      expect(methods, ['write', 'discard']);
    },
  );
}
