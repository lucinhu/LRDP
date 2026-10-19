import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../data/transfer_folder.dart';
import '../rdp/rdp_session.dart';
import 'adaptive.dart';

Future<void> showTransfers(BuildContext context, RdpSession session) =>
    showDialog<void>(
      context: context,
      builder: (_) => TransferDialog(
        directory: session.transferDirectory!,
        sharingEnabled: session.profile.fileTransfer,
        session: session,
      ),
    );

class TransferDialog extends StatefulWidget {
  const TransferDialog({
    super.key,
    required this.directory,
    this.sharingEnabled = false,
    this.session,
  });
  final String directory;
  final bool sharingEnabled;
  final RdpSession? session;
  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  late final folder = TransferFolder(widget.directory);
  String _relative = '', _error = '', _activity = '';
  List<TransferEntry>? _entries;
  bool _busy = false;
  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final entries = await folder.list(_relative);
      if (mounted) {
        setState(() {
          _entries = entries;
          _error = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _entries = [];
          _error = '无法读取目录：$e';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '操作未完成：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activity = '';
        });
      }
    }
  }

  Future<void> _upload() => _run(() async {
    final files = await openFiles();
    for (final file in files) {
      if (!mounted) break;
      setState(() => _activity = '正在放入 ${file.name}…');
      await folder.importFile(
        file.name,
        file.openRead(),
        relativeDirectory: _relative,
      );
    }
    await _refresh();
  });

  Future<void> _export(TransferEntry entry, BuildContext anchor) {
    // Adding the busy indicator can rebuild this sliver row while file I/O is
    // pending. Capture its iPad popover anchor before that asynchronous gap.
    final box = anchor.findRenderObject();
    final shareOrigin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    return _run(() async {
      final source = await folder.file(entry.path);
      if (!mounted) return;
      if (_mobile) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(source.path)],
            title: entry.name,
            sharePositionOrigin: shareOrigin,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: entry.name);
        if (location == null ||
            p.equals(p.absolute(location.path), p.absolute(source.path))) {
          return;
        }
        if (mounted) setState(() => _activity = '正在导出 ${entry.name}…');
        await source.copy(location.path);
      }
    });
  }

  void _enter(String path) {
    setState(() {
      _relative = path;
      _entries = null;
    });
    _refresh();
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GiB';
  }

  @override
  Widget build(BuildContext context) {
    if (phoneLayout(context)) return _phonePanel();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_copy_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '文件中转站',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.sharingEnabled
                    ? '连接后，在远程 Windows 文件资源管理器中打开以下路径，即可双向复制文件。服务器需允许磁盘重定向。'
                    : '请先在连接偏好中开启文件传输，再连接远程电脑。你可以提前把文件放入这里。',
              ),
              Row(
                children: [
                  const Expanded(child: SelectableText(r'\\tsclient\LRDP')),
                  IconButton(
                    onPressed: () async {
                      const path = r'\\tsclient\LRDP';
                      await Clipboard.setData(const ClipboardData(text: path));
                      if ((widget.session?.clipboardSupported ?? false)) {
                        widget.session!.clipboard(path);
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制远程路径',
                  ),
                ],
              ),
              if (!_mobile)
                Text(
                  folder.directory.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const Divider(),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _upload,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('放入本地文件'),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新收到的文件',
                  ),
                  if (_relative.isNotEmpty)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _enter(
                              p.dirname(_relative) == '.'
                                  ? ''
                                  : p.dirname(_relative),
                            ),
                      icon: const Icon(Icons.arrow_upward),
                      label: const Text('上一级'),
                    ),
                ],
              ),
              if (_relative.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _relative,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 8),
              if (_busy) const LinearProgressIndicator(),
              if (_activity.isNotEmpty)
                Text(_activity, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (_error.isNotEmpty)
                Text(
                  _error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: _entries == null
                    ? const Center(child: CircularProgressIndicator())
                    : _entries!.isEmpty
                    ? const Center(
                        child: Text(
                          '这里还没有文件\n放入本地文件，或从远程电脑复制文件到此处。',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: _entries!.length,
                        itemBuilder: (context, index) {
                          final entry = _entries![index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              entry.directory
                                  ? Icons.folder_outlined
                                  : Icons.insert_drive_file_outlined,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              entry.directory ? '文件夹' : _size(entry.bytes),
                            ),
                            onTap: entry.directory && !_busy
                                ? () => _enter(entry.path)
                                : null,
                            trailing: entry.directory
                                ? const Icon(Icons.chevron_right)
                                : Builder(
                                    builder: (anchor) => IconButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _export(entry, anchor),
                                      icon: Icon(
                                        _mobile
                                            ? Icons.ios_share
                                            : Icons.save_alt,
                                      ),
                                      tooltip: _mobile ? '保存或分享' : '另存到本地',
                                    ),
                                  ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 6),
              const Text(
                '文件保留在本地；关闭文件传输并重新连接后，远程电脑将无法访问此目录。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phonePanel() => Dialog.fullscreen(
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '文件中转站',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text(r'\\tsclient\LRDP'),
                  subtitle: const Text('远程电脑中的共享路径 · 点按查看用法'),
                  trailing: IconButton(
                    tooltip: '复制远程路径',
                    icon: const Icon(Icons.copy),
                    onPressed: () async {
                      const path = r'\\tsclient\LRDP';
                      await Clipboard.setData(const ClipboardData(text: path));
                      if (widget.session?.clipboardSupported ?? false) {
                        widget.session!.clipboard(path);
                      }
                    },
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        widget.sharingEnabled
                            ? '放入本地文件后，在远程 Windows 文件资源管理器打开上方路径，即可双向复制文件。服务器需允许磁盘重定向。收到文件后，点右侧分享按钮保存到手机。'
                            : '请先在连接偏好中开启文件传输，再连接远程电脑。你可以提前把文件放入这里。',
                      ),
                    ),
                  ],
                ),
                if (_relative.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_relative),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_activity.isNotEmpty) Text(_activity),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_entries == null)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_entries!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      '还没有文件\n放入本地文件，或从远程电脑复制文件到此处。',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  for (final entry in _entries!)
                    ListTile(
                      minTileHeight: 72,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        entry.directory
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        entry.directory ? '文件夹' : _size(entry.bytes),
                      ),
                      onTap: entry.directory && !_busy
                          ? () => _enter(entry.path)
                          : null,
                      trailing: entry.directory
                          ? const Icon(Icons.chevron_right)
                          : Builder(
                              builder: (anchor) => IconButton(
                                onPressed: _busy
                                    ? null
                                    : () => _export(entry, anchor),
                                tooltip: _mobile ? '保存或分享' : '另存到本地',
                                icon: Icon(
                                  _mobile ? Icons.ios_share : Icons.save_alt,
                                ),
                              ),
                            ),
                    ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '文件保留在此连接的中转站中，断开连接不会删除。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _upload,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('放入本地文件'),
                  ),
                ),
                if (_relative.isNotEmpty)
                  IconButton(
                    tooltip: '上一级',
                    onPressed: _busy
                        ? null
                        : () => _enter(
                            p.dirname(_relative) == '.'
                                ? ''
                                : p.dirname(_relative),
                          ),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                IconButton(
                  onPressed: _busy ? null : _refresh,
                  tooltip: '刷新收到的文件',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
