import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_version.dart';
import '../data/profile_store.dart';
import '../l10n/app_strings.dart';
import '../updates/github_updates.dart';

class UpdateCard extends StatefulWidget {
  const UpdateCard({
    super.key,
    required this.store,
    this.updates,
    this.openUrl,
    this.target,
  });
  final ProfileStore store;
  final GithubUpdates? updates;
  final Future<bool> Function(Uri)? openUrl;
  final UpdateTarget? target;
  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  bool _busy = false;
  UpdateCheck? _result;
  String? _error;
  ProfileStore get store => widget.store;

  Future<void> _open(Uri url) async {
    try {
      final opened =
          await (widget.openUrl?.call(url) ??
              launchUrl(url, mode: LaunchMode.externalApplication));
      if (opened) return;
    } catch (_) {
      /* Show the copyable link when no browser is available. */
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('无法打开浏览器')),
        content: SelectableText(url.toString()),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url.toString()));
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(context.tr('复制链接')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('关闭')),
          ),
        ],
      ),
    );
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
    });
    try {
      final token = await store.githubUpdateToken();
      final result = await (widget.updates ?? GithubUpdates()).check(
        includePrereleases: store.includePreviewUpdates,
        token: token,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _busy = false;
      });
      if (result.hasUpdate) await _showRelease(result.latest!);
    } on UpdateException catch (failure) {
      if (mounted) {
        setState(
          () => _error = switch (failure.reason) {
            UpdateFailure.network => '无法检查更新，请检查网络后重试。',
            UpdateFailure.unavailable =>
              '无法访问发布信息。私有仓库需要有读取权限的 GitHub 令牌，也可在浏览器中登录后查看。',
            UpdateFailure.authentication => 'GitHub 令牌无效或没有读取权限，请更新令牌后重试。',
            UpdateFailure.rateLimited => 'GitHub 请求次数已达上限，请稍后重试。',
            UpdateFailure.invalidData => '无法识别发布信息，请打开发布页面查看。',
          },
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取更新令牌，请检查系统安全存储或重新配置令牌。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRelease(GithubRelease release) => showDialog<void>(
    context: context,
    builder: (context) {
      final asset = release.assetFor(widget.target ?? UpdateTarget.current);
      return AlertDialog(
        scrollable: true,
        title: Text(context.tr('发现新版本 {0}', [release.tag])),
        content: SizedBox(
          width: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (release.prerelease) ...[
                Text(context.tr('这是预览版本。')),
                const SizedBox(height: 12),
              ],
              SelectableText(
                release.notes.isEmpty
                    ? context.tr('此版本未提供发布说明。')
                    : release.notes,
              ),
              if (asset == null) ...[
                const SizedBox(height: 16),
                Text(context.tr('此版本未提供适用于当前系统和架构的安装包，可前往发布页面查看。')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('稍后')),
          ),
          TextButton(
            onPressed: () => _open(release.url),
            child: Text(context.tr('查看发布页面')),
          ),
          if (asset != null)
            FilledButton.icon(
              onPressed: () => _open(asset.url),
              icon: const Icon(Icons.open_in_browser_rounded),
              label: Text(context.tr('下载安装包')),
            ),
        ],
      );
    },
  );

  Future<void> _configureToken() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateTokenDialog(
      store: store,
      onSaved: () {
        if (mounted) {
          setState(() {
            _result = null;
            _error = null;
          });
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('updateCard'),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('应用更新'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            context.tr('当前版本：{0}（构建 {1}）', [
              appReleaseTag,
              appPackageVersion.split('+').last,
            ]),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr('包含预览版本')),
            value: store.includePreviewUpdates,
            onChanged: _busy
                ? null
                : (value) async {
                    try {
                      await store.setIncludePreviewUpdates(value);
                      if (mounted) {
                        setState(() {
                          _result = null;
                          _error = null;
                        });
                      }
                    } catch (_) {
                      if (mounted) setState(() => _error = '设置未能保存，请检查存储空间后重试');
                    }
                  },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.tr(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _result!.hasUpdate
                    ? context.tr('发现新版本 {0}', [_result!.latest!.tag])
                    : _result!.latest == null
                    ? context.tr('此更新通道尚无可用发布。')
                    : context.tr('未发现比当前版本更新的发布。'),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('checkUpdates'),
                onPressed: _busy ? null : _check,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt_rounded),
                label: Text(context.tr(_busy ? '正在检查…' : '检查更新')),
              ),
              if (_result?.hasUpdate == true)
                OutlinedButton(
                  onPressed: () => _showRelease(_result!.latest!),
                  child: Text(context.tr('查看更新')),
                ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _open(GithubUpdates.releasesPage),
                child: Text(context.tr('查看发布页面')),
              ),
              TextButton(
                onPressed: _busy ? null : _configureToken,
                child: Text(context.tr('GitHub 访问令牌')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _UpdateTokenDialog extends StatefulWidget {
  const _UpdateTokenDialog({required this.store, required this.onSaved});
  final ProfileStore store;
  final VoidCallback onSaved;
  @override
  State<_UpdateTokenDialog> createState() => _UpdateTokenDialogState();
}

class _UpdateTokenDialogState extends State<_UpdateTokenDialog> {
  final _input = TextEditingController();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save(String? token) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.setGithubUpdateToken(token);
      widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '令牌未能保存，请检查系统安全存储后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(context.tr('GitHub 访问令牌')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                '公开仓库无需令牌。私有仓库请使用仅授权 LRDP 仓库、Contents 只读权限的 GitHub 令牌。令牌仅保存在系统安全存储中。',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('githubUpdateToken'),
              controller: _input,
              enabled: !_saving,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 1024,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: context.tr('访问令牌'),
                helperText: widget.store.hasGithubUpdateToken
                    ? context.tr('已有已保存的令牌；输入可替换。')
                    : null,
                helperMaxLines: 3,
              ),
            ),
            if (_error != null)
              Text(
                context.tr(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.store.hasGithubUpdateToken)
          TextButton(
            onPressed: _saving ? null : () => _save(null),
            child: Text(context.tr('移除令牌')),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('取消')),
        ),
        FilledButton(
          onPressed: _saving || _input.text.trim().isEmpty
              ? null
              : () => _save(_input.text),
          child: Text(context.tr(_saving ? '正在保存…' : '保存')),
        ),
      ],
    ),
  );
}
