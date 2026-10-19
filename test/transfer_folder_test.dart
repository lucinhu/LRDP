import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/transfer_folder.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late TransferFolder folder;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lrdp-transfer-test-');
    folder = TransferFolder(directory.path);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('file sharing defaults off and is isolated by connection', () {
    const profile = ConnectionProfile(id: 'a', name: 'test', host: 'localhost');
    expect(profile.fileTransfer, isFalse);
    expect(ConnectionProfile.fromJson(profile.toJson()).fileTransfer, isFalse);
    final enabled = profile.copyWith(fileTransfer: true);
    expect(ConnectionProfile.fromJson(enabled.toJson()).fileTransfer, isTrue);
    final first = TransferFolder.pathFor(directory.path, profile);
    final second = TransferFolder.pathFor(
      directory.path,
      const ConnectionProfile(id: '../b', name: 'test', host: 'localhost'),
    );
    expect(p.isWithin(directory.path, first), isTrue);
    expect(p.isWithin(directory.path, second), isTrue);
    expect(first, isNot(second));
  });

  test(
    'streamed uploads preserve Chinese names, content and existing files',
    () async {
      final payload = utf8.encode('中文文件内容\n');
      final first = await folder.importFile('测试.txt', Stream.value(payload));
      final second = await folder.importFile(
        '../测试.txt',
        Stream.value([1, 2, 3]),
      );
      expect(first, '测试.txt');
      expect(second, '测试 (1).txt');
      expect(await (await folder.file(first)).readAsBytes(), payload);
      expect(await (await folder.file(second)).readAsBytes(), [1, 2, 3]);
      expect((await folder.list()).length, 2);
      expect(await File(p.join(directory.path, '测试.txt')).exists(), isTrue);
    },
  );

  test(
    'browsing and exporting reject traversal and external symbolic links',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'lrdp-outside-test-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await File(p.join(outside.path, 'secret')).writeAsString('private');
      await Link(p.join(directory.path, 'escape')).create(outside.path);
      expect(await folder.list(), isEmpty);
      await expectLater(folder.list('..'), throwsA(isA<FileSystemException>()));
      await expectLater(
        folder.file('escape/secret'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        folder.importFile('x', Stream.value([1]), relativeDirectory: '../'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'interrupted upload leaves no public file and nested folders work',
    () async {
      await expectLater(
        folder.importFile(
          'broken.txt',
          Stream.error(const FileSystemException('interrupted')),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await folder.list(), isEmpty);
      await Directory(p.join(directory.path, 'reports')).create();
      await folder.importFile(
        '报告.csv',
        Stream.value(utf8.encode('a,b')),
        relativeDirectory: 'reports',
      );
      final entries = await folder.list('reports');
      expect(entries.single.name, '报告.csv');
    },
  );
}
