import '../l10n/app_strings.dart';
import 'package:flutter/material.dart';
import '../models/connection_profile.dart';

typedef LoginDetails = ({String username, String domain, String password});

class LoginDialog extends StatefulWidget {
  const LoginDialog({
    super.key,
    required this.profile,
    this.password = '',
    this.issue,
  });
  final ConnectionProfile profile;
  final String password;
  final String? issue;
  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _form = GlobalKey<FormState>();
  late final _user = TextEditingController(text: widget.profile.username);
  late final _domain = TextEditingController(text: widget.profile.domain);
  late final _secret = TextEditingController(text: widget.password);
  @override
  void dispose() {
    _user.dispose();
    _domain.dispose();
    _secret.dispose();
    super.dispose();
  }

  String? _valid(String? value) =>
      value?.contains('\u0000') == true ? context.tr('登录信息包含无效字符') : null;
  void _connect() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop<LoginDetails>(context, (
      username: _user.text.trim(),
      domain: _domain.text.trim(),
      password: _secret.text,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(
      context.tr(widget.issue == null ? '连接到 {0}' : '重新登录 {0}', [
        widget.profile.name,
      ]),
    ),
    content: SizedBox(
      width: 380,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.profile.address,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.issue case final issue?) ...[
              const SizedBox(height: 12),
              Text(context.tr(issue)),
            ],
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('loginUser'),
              controller: _user,
              autofocus: widget.profile.username.isEmpty,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: context.tr("用户名")),
              validator: (value) => value == null || value.trim().isEmpty
                  ? context.tr('请输入用户名')
                  : _valid(value),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('loginDomain'),
              controller: _domain,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              validator: _valid,
              decoration: InputDecoration(labelText: context.tr("域（选填）")),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('loginPassword'),
              controller: _secret,
              autofocus: widget.profile.username.isNotEmpty,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              validator: _valid,
              decoration: InputDecoration(labelText: context.tr("密码")),
              onFieldSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr("本次输入仅用于当前会话。需要在设备上保存时，请使用“编辑连接”。"),
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr("取消")),
      ),
      FilledButton(
        key: const Key('submitLogin'),
        onPressed: _connect,
        child: Text(context.tr("连接")),
      ),
    ],
  );
}
