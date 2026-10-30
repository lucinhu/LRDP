import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/diagnostics.dart';
import '../data/profile_store.dart';
import '../l10n/app_strings.dart';

/// Shows a sanitized support report with one copy action.
Future<void> showDiagnosticsSheet(
  BuildContext context,
  ProfileStore store,
) async {
  final report = await collectDiagnostics(store);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _DiagnosticsSheet(report: report),
  );
}

class _DiagnosticsSheet extends StatefulWidget {
  const _DiagnosticsSheet({required this.report});
  final String report;
  @override
  State<_DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends State<_DiagnosticsSheet> {
  // The confirmation must be readable while the sheet is open. A SnackBar
  // owned by the page Scaffold would paint behind the modal route, so the
  // sheet carries its own ScaffoldMessenger/Scaffold pair.
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  bool _copying = false;

  Future<void> _copy() async {
    if (_copying) return;
    setState(() => _copying = true);
    final strings =
        Localizations.of<AppStrings>(context, AppStrings) ??
        AppStrings.fallback;
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: widget.report));
      message = strings.text('诊断信息已复制');
    } catch (e) {
      message = strings.text('复制失败：{0}', [e]);
    }
    if (!mounted) return;
    setState(() => _copying = false);
    _messenger.currentState?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = math.min(MediaQuery.sizeOf(context).height * 0.62, 460.0);
    return SizedBox(
      height: height,
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr('仅包含版本、平台与显示设置，不含连接地址和凭据。'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        widget.report,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _copying ? null : _copy,
                  icon: const Icon(Icons.copy),
                  label: Text(context.tr('复制诊断信息')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
