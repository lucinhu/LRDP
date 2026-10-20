import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/clipboard_files.dart';

class DeclaredFile extends XFile {
  DeclaredFile(super.path, this.size, [this.contents = const []]);
  final int size;
  final List<int> contents;
  @override
  Future<int> length() async => size;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      Stream.value(Uint8List.fromList(contents));
}

void main() {
  test(
    'snapshots preserve Unicode, binary and empty files in private storage',
    () async {
      final batch = await ClipboardFiles.prepare([
        XFile.fromData(Uint8List.fromList([0, 255, 128]), path: '中文 😀.bin'),
        XFile.fromData(Uint8List(0), path: 'empty.txt'),
      ], isCurrent: () => true);
      final root = batch.directory;
      expect(await File(batch.paths[0]).readAsBytes(), [0, 255, 128]);
      expect(await File(batch.paths[1]).length(), 0);
      expect(batch.paths[0], endsWith('中文 😀.bin'));
      await batch.dispose();
      expect(await root.exists(), false);
    },
  );

  test(
    'rejects count, duplicate, reserved and nonportable names before copying',
    () async {
      final invalid = <List<XFile>>[
        [],
        List.generate(33, (i) => DeclaredFile('$i.bin', 0)),
        [DeclaredFile('A.txt', 0), DeclaredFile('a.txt', 0)],
        for (final name in [
          'CON.txt',
          'COM¹.txt',
          'test?.txt',
          'test.',
          'test ',
          r'a\b',
        ])
          [DeclaredFile(name, 0)],
      ];
      for (final files in invalid) {
        await expectLater(
          ClipboardFiles.prepare(files, isCurrent: () => true),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects excessive metadata without buffering large files', () async {
    for (final files in [
      [DeclaredFile('large', ClipboardFiles.maxFileBytes + 1)],
      [
        DeclaredFile('a', ClipboardFiles.maxFileBytes),
        DeclaredFile('b', ClipboardFiles.maxFileBytes),
        DeclaredFile('c', 1),
      ],
    ]) {
      await expectLater(
        ClipboardFiles.prepare(files, isCurrent: () => true),
        throwsFormatException,
      );
    }
  });

  test(
    'changed input and cancellation leave no private partial snapshot',
    () async {
      final isolated = await Directory.systemTemp.createTemp(
        'lrdp-stage-test-',
      );
      try {
        await IOOverrides.runZoned(() async {
          Set<String> staged() => Directory.systemTemp
              .listSync()
              .whereType<Directory>()
              .map((d) => d.path)
              .where((path) => path.contains('lrdp-file-paste-'))
              .toSet();
          final before = staged();
          for (final file in [
            DeclaredFile('short', 4, [1]),
            DeclaredFile('growing', 1, [1, 2]),
          ]) {
            await expectLater(
              ClipboardFiles.prepare([file], isCurrent: () => true),
              throwsFormatException,
            );
            expect(staged(), before);
          }
          var checks = 0;
          await expectLater(
            ClipboardFiles.prepare([
              DeclaredFile('cancel', 1, [1]),
            ], isCurrent: () => ++checks == 1),
            throwsA(isA<FileSystemException>()),
          );
          expect(checks, greaterThan(1));
          expect(staged(), before);
        }, getSystemTempDirectory: () => isolated);
      } finally {
        await isolated.delete(recursive: true);
      }
    },
  );
}
