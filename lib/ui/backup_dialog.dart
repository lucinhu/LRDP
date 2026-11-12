import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/profile_backup.dart';
import '../data/profile_store.dart';
import '../l10n/app_strings.dart';

const _jsonFileTypes = [
  XTypeGroup(label: 'JSON', extensions: ['json']),
];

/// Opens the configuration backup dialog and performs the chosen transfer.
///
/// The dialog closes before any file chooser opens, so the platform picker is
/// never stacked on top of the app dialog. [savePath] and [openPath] are
/// injectable for tests; the defaults use `file_selector` on the current
/// platform.
Future<void> showBackupDialog(
  BuildContext context,
  ProfileStore store, {
  Future<String?> Function(String suggestedName)? savePath,
  Future<String?> Function()? openPath,
}) async {
  final action = await showDialog<_BackupAction>(
    context: context,
    builder: (_) => const _BackupDialog(),
  );
  if (action == null) return;
  if (!context.mounted) return;
  // Snackbars must outlive the dialog route this function was opened from.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final strings =
      Localizations.of<AppStrings>(context, AppStrings) ?? AppStrings.fallback;
  void message(String source, [List<Object?> values = const []]) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(strings.text(source, values)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  if (action == _BackupAction.export) {
    await _export(store, savePath ?? _pickSavePath, message);
  } else {
    await _import(store, openPath ?? _pickOpenPath, message);
  }
}

typedef _Message = void Function(String source, [List<Object?> values]);

Future<String?> _pickSavePath(String suggestedName) async {
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: _jsonFileTypes,
  );
  return location?.path;
}

Future<String?> _pickOpenPath() async {
  final file = await openFile(acceptedTypeGroups: _jsonFileTypes);
  return file?.path;
}

Future<void> _export(
  ProfileStore store,
  Future<String?> Function(String suggestedName) pickPath,
  _Message message,
) async {
  final profiles = store.profiles;
  if (profiles.isEmpty) {
    message('备份文件中没有连接');
    return;
  }
  final bytes = utf8.encode(encodeBackup(profiles));
  if (bytes.length > backupMaxBytes) {
    message('备份文件不能大于 8 MiB');
    return;
  }
  final String? path;
  try {
    path = await pickPath(backupSuggestedFileName);
  } catch (error) {
    message('操作未完成：{0}', [error]);
    return;
  }
  if (path == null) return;
  try {
    await File(path).writeAsBytes(bytes);
  } catch (error) {
    message('操作未完成：{0}', [error]);
    return;
  }
  message('已导出 {0} 个连接', [profiles.length]);
}

Future<void> _import(
  ProfileStore store,
  Future<String?> Function() pickPath,
  _Message message,
) async {
  final String? path;
  try {
    path = await pickPath();
  } catch (error) {
    message('无法读取备份文件：{0}', [error]);
    return;
  }
  if (path == null) return;
  final String? text;
  try {
    text = await _readBackupFile(File(path));
  } catch (error) {
    message('无法读取备份文件：{0}', [error]);
    return;
  }
  if (text == null) {
    message('备份文件不能大于 8 MiB');
    return;
  }
  final parsed = decodeBackup(text);
  final error = parsed.error;
  if (error != null) {
    message(error == BackupError.empty ? '备份文件中没有连接' : '备份文件格式不正确');
    return;
  }
  try {
    final merged = await store.importBackup(parsed.profiles);
    message('已导入 {0} 个连接，跳过 {1} 个重复连接', [merged.imported, merged.skipped]);
  } catch (error) {
    message('操作未完成：{0}', [error]);
  }
}

/// null means too large. Bound both the initial size and every stream block so
/// a file that grows after the stat cannot bypass the limit.
Future<String?> _readBackupFile(File file) async {
  if (await file.length() > backupMaxBytes) return null;
  final bytes = BytesBuilder(copy: false);
  await for (final block in file.openRead()) {
    if (bytes.length + block.length > backupMaxBytes) return null;
    bytes.add(block);
  }
  return utf8.decode(bytes.takeBytes());
}

enum _BackupAction { export, import }

class _BackupDialog extends StatelessWidget {
  const _BackupDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.settings_backup_restore),
    title: Text(context.tr('配置备份')),
    content: SizedBox(
      width: 420,
      child: Text(context.tr('备份包含所有连接配置，不含密码和证书指纹。')),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr('关闭')),
      ),
      FilledButton.tonalIcon(
        onPressed: () => Navigator.pop(context, _BackupAction.export),
        icon: const Icon(Icons.save_alt),
        label: Text(context.tr('导出配置备份')),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.pop(context, _BackupAction.import),
        icon: const Icon(Icons.restore),
        label: Text(context.tr('导入配置备份')),
      ),
    ],
  );
}
