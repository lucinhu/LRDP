import '../l10n/app_strings.dart';
import 'package:flutter/material.dart';

typedef CertificateAcceptance = ({bool remember});

class CertificateDialog extends StatefulWidget {
  const CertificateDialog({
    super.key,
    required this.address,
    required this.fingerprint,
    this.previousFingerprint = '',
  });

  final String address, fingerprint, previousFingerprint;

  @override
  State<CertificateDialog> createState() => _CertificateDialogState();
}

class _CertificateDialogState extends State<CertificateDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    // The previous login IME can still be animating away when this opens.
    // Keep the content scrollable while the actions remain reachable.
    scrollable: true,
    icon: Icon(
      widget.previousFingerprint.isEmpty
          ? Icons.verified_user_outlined
          : Icons.gpp_maybe_outlined,
      size: 36,
      color: Theme.of(context).colorScheme.primary,
    ),
    title: Text(
      widget.previousFingerprint.isEmpty
          ? context.tr("确认远程电脑的身份")
          : context.tr("远程电脑的证书发生变化"),
    ),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr("系统无法自动验证 {0}。请通过可信渠道核对 SHA-256 指纹后再连接。", [
              widget.address,
            ]),
          ),
          const SizedBox(height: 16),
          SelectableText(
            widget.fingerprint,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (widget.previousFingerprint.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(context.tr("原指纹"), style: TextStyle(fontSize: 12)),
            SelectableText(
              widget.previousFingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
          const SizedBox(height: 16),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _remember,
            onChanged: (value) => setState(() => _remember = value!),
            title: Text(context.tr("在此设备记住这个指纹")),
            subtitle: Text(
              context.tr("证书变化时会再次询问"),
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr("取消连接")),
      ),
      FilledButton(
        onPressed: widget.fingerprint.isEmpty
            ? null
            : () => Navigator.pop<CertificateAcceptance>(context, (
                remember: _remember,
              )),
        child: Text(context.tr("指纹匹配，继续")),
      ),
    ],
  );
}
