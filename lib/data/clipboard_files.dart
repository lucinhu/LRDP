import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

/// Snapshots selected files outside the redirected drive. The native adapter
/// pins read-only handles before the staging directory is removed.
class ClipboardFiles {
  ClipboardFiles._(this.directory, this.paths);
  final Directory directory;
  final List<String> paths;
  static const maxCount = 32;
  static const maxFileBytes = 256 * 1024 * 1024;
  static const maxTotalBytes = 512 * 1024 * 1024;

  static Future<ClipboardFiles> prepare(
    List<XFile> files, {
    required bool Function() isCurrent,
  }) async {
    if (files.isEmpty || files.length > maxCount) {
      throw const FormatException('每次请选择 1 至 32 个文件');
    }
    final names = <String>{};
    final lengths = <int>[];
    var total = 0;
    for (final file in files) {
      final name = file.name;
      final stem = name.split('.').first.trim().toUpperCase();
      if (name.isEmpty ||
          name.length > 200 ||
          RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
          name.endsWith('.') ||
          name.endsWith(' ') ||
          RegExp(
            r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$',
          ).hasMatch(stem)) {
        throw const FormatException('文件名无效或过长');
      }
      if (!names.add(name.toLowerCase())) {
        throw const FormatException('所选文件名重复，请分次粘贴');
      }
      final length = await file.length();
      total += length;
      if (length < 0 || length > maxFileBytes || total > maxTotalBytes) {
        throw const FormatException('每个文件最大 256 MiB，每次合计最大 512 MiB');
      }
      lengths.add(length);
    }
    if (!isCurrent()) throw const FileSystemException('文件准备已取消');
    final directory = await Directory.systemTemp.createTemp('lrdp-file-paste-');
    final paths = <String>[];
    try {
      for (var i = 0; i < files.length; i++) {
        final parent = await Directory(p.join(directory.path, '$i')).create();
        final target = File(p.join(parent.path, files[i].name));
        final sink = target.openWrite();
        try {
          var copied = 0;
          await for (final block in files[i].openRead()) {
            if (!isCurrent()) {
              throw const FileSystemException('文件准备已取消');
            }
            copied += block.length;
            if (copied > lengths[i]) {
              throw const FormatException('文件在读取时发生变化，请重新选择');
            }
            sink.add(block);
            // Bound queued writes as well as the input stream's chunk size.
            await sink.flush();
          }
          if (copied != lengths[i]) {
            throw const FormatException('文件在读取时发生变化，请重新选择');
          }
        } finally {
          await sink.close();
        }
        paths.add(target.path);
      }
      if (!isCurrent()) throw const FileSystemException('文件准备已取消');
      return ClipboardFiles._(directory, paths);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A platform may defer unlinking an open handle until session teardown.
    }
  }
}
