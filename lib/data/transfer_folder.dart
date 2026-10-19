import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/connection_profile.dart';

class TransferEntry {
  const TransferEntry(this.path, this.name, this.directory, this.bytes);
  final String path, name;
  final bool directory;
  final int bytes;
}

/// A per-connection exchange folder. RDP receives only this directory, never
/// an implicit list of local drives. File contents are streamed, not buffered.
class TransferFolder {
  TransferFolder(String path) : directory = Directory(path);
  final Directory directory;

  static String pathFor(String protocolDirectory, ConnectionProfile profile) {
    if (profile.sharedDirectory.isNotEmpty &&
        !Platform.isAndroid &&
        !Platform.isIOS) {
      if (!p.isAbsolute(profile.sharedDirectory)) {
        throw const FormatException('共享目录需要使用绝对路径');
      }
      return profile.sharedDirectory;
    }
    final id = base64Url.encode(utf8.encode(profile.id)).replaceAll('=', '');
    if (id.isEmpty || id.length > 200) {
      throw const FormatException('连接标识不正确');
    }
    return p.join(protocolDirectory, 'transfers', id);
  }

  String _inside(String relative) {
    final root = p.normalize(p.absolute(directory.path));
    final target = p.normalize(p.join(root, relative));
    if (target != root && !p.isWithin(root, target)) {
      throw const FileSystemException('文件超出共享目录');
    }
    return target;
  }

  Future<String> _checked(String relative) async {
    final target = _inside(relative);
    final actual = await File(target).resolveSymbolicLinks();
    final root = await directory.resolveSymbolicLinks();
    if (actual != root && !p.isWithin(root, actual)) {
      throw const FileSystemException('文件链接超出共享目录');
    }
    return actual;
  }

  Future<List<TransferEntry>> list([String relative = '']) async {
    final target = Directory(await _checked(relative));
    final entries = <TransferEntry>[];
    await for (final entity in target.list(followLinks: false)) {
      final stat = await entity.stat();
      if (entity is Link || stat.type == FileSystemEntityType.notFound) {
        continue;
      }
      final isDirectory = stat.type == FileSystemEntityType.directory;
      if (!isDirectory && stat.type != FileSystemEntityType.file) continue;
      entries.add(
        TransferEntry(
          p.relative(entity.path, from: directory.path),
          p.basename(entity.path),
          isDirectory,
          stat.size,
        ),
      );
    }
    entries.sort(
      (a, b) => a.directory == b.directory
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : a.directory
          ? -1
          : 1,
    );
    return entries;
  }

  Future<File> file(String relative) async {
    final path = await _checked(relative);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('请选择普通文件');
    }
    return File(path);
  }

  Future<String> importFile(
    String name,
    Stream<List<int>> contents, {
    String relativeDirectory = '',
  }) async {
    // Treat both kinds of separators as unsafe on every platform. Windows
    // reserved characters are normalized to keep transferred names portable.
    final safe = name
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..' || safe.length > 200) {
      throw const FormatException('文件名无效或过长');
    }
    final parent = Directory(await _checked(relativeDirectory));
    final stem = p.basenameWithoutExtension(safe),
        extension = p.extension(safe);
    String candidate = safe;
    for (
      var i = 1;
      await FileSystemEntity.type(
            p.join(parent.path, candidate),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound;
      i++
    ) {
      candidate = '$stem ($i)$extension';
    }
    // Stage outside the advertised directory before publishing the final name.
    final staging = await Directory.systemTemp.createTemp('lrdp-upload-');
    try {
      final temporary = File(p.join(staging.path, 'contents'));
      final sink = temporary.openWrite();
      try {
        await sink.addStream(contents);
      } finally {
        await sink.close();
      }
      try {
        await temporary.rename(p.join(parent.path, candidate));
      } on FileSystemException catch (e) {
        // EXDEV: a selected desktop directory may be on another filesystem.
        if (e.osError?.errorCode != (Platform.isWindows ? 17 : 18)) rethrow;
        final pending = await parent.createTemp('.lrdp-upload-');
        try {
          final staged = await temporary.copy(p.join(pending.path, candidate));
          await staged.rename(p.join(parent.path, candidate));
        } finally {
          await pending.delete(recursive: true);
        }
      }
    } finally {
      await staging.delete(recursive: true);
    }
    return candidate;
  }
}
