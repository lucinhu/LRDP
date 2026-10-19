import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import '../models/connection_profile.dart';
import 'adaptive.dart';

class ProfileEditResult {
  const ProfileEditResult(this.profile, this.password, this.connect);
  final ConnectionProfile profile;
  final String password;
  final bool connect;
}

Future<ProfileEditResult?> editProfile(
  BuildContext context, {
  ConnectionProfile? profile,
  String password = '',
  String? address,
  bool focusPassword = false,
  String? notice,
}) => showDialog<ProfileEditResult>(
  context: context,
  builder: (_) => ProfileEditor(
    profile: profile,
    password: password,
    address: address,
    focusPassword: focusPassword,
    notice: notice,
  ),
);

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    this.profile,
    this.password = '',
    this.address,
    this.focusPassword = false,
    this.notice,
  });
  final ConnectionProfile? profile;
  final String password;
  final String? address, notice;
  final bool focusPassword;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _address = TextEditingController(
    text: widget.address ?? widget.profile?.address ?? '',
  );
  late final _username = TextEditingController(
    text: widget.profile?.username ?? '',
  );
  late final _domain = TextEditingController(
    text: widget.profile?.domain ?? '',
  );
  late final _password = TextEditingController(text: widget.password);
  late final _group = TextEditingController(
    text: widget.profile?.group ?? '个人',
  );
  late bool _remember = widget.profile?.rememberPassword ?? false;
  late bool _autoReconnect = widget.profile?.autoReconnect ?? true;
  late bool _clipboard = widget.profile?.clipboard ?? true;
  late bool _audio = widget.profile?.audio ?? false;
  late bool _fileTransfer = widget.profile?.fileTransfer ?? false;
  late String _sharedDirectory = widget.profile?.sharedDirectory ?? '';
  late bool _nla = widget.profile?.nla ?? true;
  bool _visible = false;
  late String _resolution =
      '${widget.profile?.width ?? 1280}×${widget.profile?.height ?? 800}';

  @override
  void dispose() {
    for (final c in [_name, _address, _username, _domain, _password, _group]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit(bool connect) {
    if (!_form.currentState!.validate()) return;
    final endpoint = Endpoint.parse(_address.text);
    final size = _resolution.split('×');
    final p = ConnectionProfile(
      id: widget.profile?.id ?? ConnectionProfile.newId(),
      name: _name.text.trim().isEmpty ? endpoint.host : _name.text.trim(),
      host: endpoint.host,
      port: endpoint.port,
      username: _username.text.trim(),
      domain: _domain.text.trim(),
      group: _group.text.trim().isEmpty ? '个人' : _group.text.trim(),
      favorite: widget.profile?.favorite ?? false,
      width: int.parse(size[0]),
      height: int.parse(size[1]),
      clipboard: _clipboard,
      audio: _audio,
      autoReconnect: _autoReconnect,
      fileTransfer: _fileTransfer,
      sharedDirectory: _sharedDirectory,
      nla: _nla,
      rememberPassword: _remember,
      lastConnectedAt: widget.profile?.lastConnectedAt,
    );
    Navigator.pop(context, ProfileEditResult(p, _password.text, connect));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolutions = {
      '1280×800',
      '1366×768',
      '1920×1080',
      '2560×1440',
      '3840×2160',
      _resolution,
    }.toList();
    final phone = phoneLayout(context);
    Widget content({bool compact = false}) => Form(
      key: _form,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.symmetric(
          horizontal: phone ? 20 : 28,
          vertical: compact ? 4 : (phone ? 20 : 28),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!phone) ...[_header(), const SizedBox(height: 26)],
            if (widget.notice case final notice?) ...[
              Text(notice, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
            ],
            TextFormField(
              key: const Key('profileAddress'),
              controller: _address,
              autofocus: !phone && !widget.focusPassword,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '电脑地址',
                hintText: '192.168.1.10:3389',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              validator: (v) {
                try {
                  Endpoint.parse(v ?? '');
                  return null;
                } on FormatException catch (e) {
                  return e.message;
                }
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '显示名称（选填）',
                hintText: '例如：办公室工作站',
              ),
            ),
            const SizedBox(height: 16),
            _pair(phone, [
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  hintText: 'Administrator',
                ),
              ),
              TextFormField(
                controller: _domain,
                decoration: const InputDecoration(
                  labelText: '域（选填）',
                  hintText: 'WORKGROUP',
                ),
              ),
            ]),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('profilePassword'),
              controller: _password,
              autofocus: widget.focusPassword,
              obscureText: !_visible,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _visible = !_visible),
                  icon: Icon(
                    _visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  tooltip: _visible ? '隐藏密码' : '显示密码',
                ),
              ),
            ),
            CheckboxListTile(
              value: _remember,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() => _remember = v!),
              title: const Text('安全地记住密码'),
              subtitle: const Text(
                '使用此设备的系统钥匙串或加密存储',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const Divider(),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              title: const Text('连接偏好'),
              subtitle: Text(
                '$_resolution · ${_clipboard ? '剪贴板开启' : '剪贴板关闭'} · ${_nla ? 'NLA' : 'TLS'}',
              ),
              children: [
                _pair(phone, [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _resolution,
                    decoration: const InputDecoration(labelText: '远程分辨率'),
                    items: resolutions
                        .map(
                          (r) => DropdownMenuItem(
                            value: r,
                            child: Text(r, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _resolution = v!),
                  ),
                  TextFormField(
                    controller: _group,
                    decoration: const InputDecoration(labelText: '分组'),
                  ),
                ]),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _autoReconnect,
                  onChanged: (v) => setState(() => _autoReconnect = v),
                  title: const Text('掉线后自动重连'),
                  subtitle: const Text('仅对已连通的会话重试，最多 5 次；可随时取消'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _clipboard,
                  onChanged: (v) => setState(() => _clipboard = v),
                  title: const Text('共享文字剪贴板'),
                  subtitle: const Text('仅在当前会话激活时同步，最大 1 MiB'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _audio,
                  onChanged: (v) => setState(() => _audio = v),
                  title: const Text('播放远程声音'),
                  subtitle: const Text('在本机播放远程电脑的声音；下次连接生效'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _fileTransfer,
                  onChanged: (v) => setState(() => _fileTransfer = v),
                  title: const Text('文件传输'),
                  subtitle: const Text('远程电脑可读写此连接的共享目录；下次连接生效'),
                ),
                if (_fileTransfer) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      _sharedDirectory.isEmpty ? '使用文件中转站' : '使用指定目录',
                    ),
                    subtitle: Text(
                      _sharedDirectory.isEmpty
                          ? '仅共享你放入此连接中转站的文件'
                          : _sharedDirectory,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if ({
                    TargetPlatform.linux,
                    TargetPlatform.windows,
                    TargetPlatform.macOS,
                  }.contains(theme.platform))
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            try {
                              final path = await getDirectoryPath(
                                confirmButtonText: '共享此目录',
                              );
                              if (path != null && mounted) {
                                setState(() => _sharedDirectory = path);
                              }
                            } on PlatformException catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('无法选择目录：${e.message}'),
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('选择共享目录'),
                        ),
                        if (_sharedDirectory.isNotEmpty)
                          TextButton(
                            onPressed: () =>
                                setState(() => _sharedDirectory = ''),
                            child: const Text('改用中转站'),
                          ),
                      ],
                    ),
                ],
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _nla,
                  onChanged: (v) => setState(() => _nla = v),
                  title: const Text('网络级身份验证（NLA）'),
                  subtitle: const Text('推荐开启。关闭后仍使用 TLS 加密。'),
                ),
              ],
            ),

            if (!phone) ...[const SizedBox(height: 18), _actions()],
          ],
        ),
      ),
    );
    if (phone) {
      return Dialog.fullscreen(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A landscape IME can leave less space than a separate title and
              // footer need. Keep both actions and a usable field viewport.
              final compact = constraints.maxHeight < 260;
              return Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 8 : 20,
                      compact ? 0 : 8,
                      8,
                      0,
                    ),
                    child: compact
                        ? Row(
                            children: [
                              IconButton(
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close),
                                tooltip: '关闭',
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: _actions()),
                            ],
                          )
                        : _header(),
                  ),
                  Expanded(child: content(compact: compact)),
                  if (!compact) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _actions(),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: content(),
      ),
    );
  }

  Widget _header() => Row(
    children: [
      Expanded(
        child: Text(
          widget.profile == null ? '添加远程电脑' : '编辑连接',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
      IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
        tooltip: '关闭',
      ),
    ],
  );

  Widget _actions() => Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: () => _submit(false),
          child: const Text('保存连接'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton(
          key: const Key('saveAndConnect'),
          onPressed: () => _submit(true),
          child: const Text('保存并连接'),
        ),
      ),
    ],
  );

  Widget _pair(bool phone, List<Widget> fields) => phone
      ? Column(children: [fields[0], const SizedBox(height: 16), fields[1]])
      : Row(
          children: [
            Expanded(child: fields[0]),
            const SizedBox(width: 12),
            Expanded(child: fields[1]),
          ],
        );
}
