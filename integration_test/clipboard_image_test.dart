import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lrdp/rdp/clipboard_picture.dart';
import 'package:lrdp/ui/image_clipboard.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real OS image clipboard preserves pixels and rejects invalid writes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('LRDP clipboard test'))),
      );
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
      final control = Platform.environment['LRDP_IMAGE_CONTROL'];
      if (control != null) {
        final external = (await ImageClipboard.read())!;
        expect(
          external.rgba,
          rgba,
          reason: 'Read independent GTK clipboard owner',
        );
      }
      final picture = await ClipboardPicture.decode(
        rgba,
        kind: 3,
        width: 3,
        height: 2,
      );
      await ImageClipboard.write(picture);
      if (control != null) {
        File('$control/written').writeAsStringSync('ready');
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!File('$control/verified.json').existsSync() &&
            DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(
          jsonDecode(
            File('$control/verified.json').readAsStringSync(),
          )['passed'],
          true,
        );
      }
      for (var i = 0; i < 8; i++) {
        expect(
          (await ImageClipboard.read())!.rgba,
          rgba,
          reason: 'OS roundtrip $i',
        );
        await ImageClipboard.write(picture);
      }
      await expectLater(
        ImageClipboard.channel.invokeMethod<void>('write', {
          'width': 4097,
          'height': 4096,
          'rgba': Uint8List(4),
          'png': Uint8List(0),
          'dib': Uint8List(0),
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await ImageClipboard.read())!.rgba,
        rgba,
        reason: 'Invalid write preserves clipboard',
      );
      if (Platform.isAndroid) {
        final folder = await getApplicationSupportDirectory();
        await File('${folder.path}/lrdp-image-result.json').writeAsString(
          jsonEncode({
            'passed': true,
            'platform': 'Android',
            'roundtrips': 8,
            'real_clipboard_manager': true,
            'real_file_provider': true,
            'invalid_write_preserved_clipboard': true,
          }),
        );
      }
    },
  );
}
