import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../rdp/rdp_session.dart';

/// Opens a read-only panel with the live state of the frame pipeline.
///
/// The panel keeps its own sampling timer and never subscribes to the session
/// change notifier: opening it must not rebuild the remote view, and while it
/// is open it only repaints its own rows once per second.
Future<void> showSessionInfoSheet(BuildContext context, RdpSession session) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SessionInfoSheet(session: session),
  );
}

class SessionInfoSheet extends StatefulWidget {
  const SessionInfoSheet({
    super.key,
    required this.session,
    this.clock = DateTime.now,
  });

  final RdpSession session;

  /// Injectable for tests; production reads the wall clock.
  final DateTime Function() clock;

  @override
  State<SessionInfoSheet> createState() => _SessionInfoSheetState();
}

class _SessionInfoSheetState extends State<SessionInfoSheet> {
  static const _sampleInterval = Duration(seconds: 1);

  Timer? _timer;
  late DateTime _sampledAt;
  late int _sampledFrames;
  int _measuredFps = 0;

  /// Native textures count published uploads; the CPU fallback counts decoded
  /// images. Both numbers are monotonic, so the delta over one second is the
  /// frame rate the user actually sees.
  int get _frameCount => widget.session.hasVideo
      ? widget.session.frames
      : widget.session.decodedFrames;

  @override
  void initState() {
    super.initState();
    _sampledAt = widget.clock();
    _sampledFrames = _frameCount;
    _timer = Timer.periodic(_sampleInterval, (_) => _sample());
  }

  void _sample() {
    final now = widget.clock();
    final frames = _frameCount;
    final elapsed = now.difference(_sampledAt).inMicroseconds;
    final measured = elapsed <= 0
        ? 0
        : (((frames - _sampledFrames) * Duration.microsecondsPerSecond) /
                  elapsed)
              .round();
    _sampledAt = now;
    _sampledFrames = frames;
    if (!mounted) return;
    setState(() => _measuredFps = measured < 0 ? 0 : measured);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final frameRate = session.targetFrameRate;
    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(
            context.tr('会话信息'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          _row(context, '连接状态', context.tr(_stateLabel(session.state))),
          _row(
            context,
            '远程分辨率',
            session.hasVideo
                ? '${session.desktopWidth} × ${session.desktopHeight}'
                : context.tr('未知'),
          ),
          _row(
            context,
            '渲染方式',
            context.tr(session.hasVideo ? '原生纹理' : 'CPU 图像'),
          ),
          _row(
            context,
            '编码',
            context.tr(session.hasDecodedAvc ? 'H.264 视频' : '位图（GDI）'),
          ),
          _row(context, '实测帧率', context.tr('{0} 帧/秒', [_measuredFps])),
          _row(
            context,
            '帧率上限',
            frameRate == 0
                ? context.tr('自动（跟随屏幕）')
                : context.tr('{0} 帧/秒', [frameRate]),
          ),
          _row(context, '已上传帧数', '${session.textureFrames}'),
          _row(context, '已解码帧数', '${session.decodedFrames}'),
          _row(context, '音频状态', context.tr(_audioLabel(session.audioStatus))),
          _row(context, '剪贴板能力', _clipboardLabel(context, session)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              context.tr(label),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            value,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.end,
          ),
        ],
      ),
    );
  }

  String _stateLabel(SessionState state) => switch (state) {
    SessionState.connecting => '连接中',
    SessionState.connected => '已连接',
    SessionState.closed => '已断开',
    SessionState.failed => '连接失败',
    SessionState.certificateRequired => '需要证书',
    SessionState.idle => '未知',
  };

  String _audioLabel(String status) => switch (status) {
    'off' => '已关闭',
    'paused' => '已暂停',
    'pausing' => '正在暂停',
    'waiting' => '等待音频',
    'playing' => '正在播放',
    'unavailable' => '不可用',
    _ => '未知',
  };

  String _clipboardLabel(BuildContext context, RdpSession session) {
    final parts = <String>[
      if (session.clipboardSupported) context.tr('文本'),
      if (session.imageClipboardSupported) context.tr('图片'),
      if (session.fileClipboardSupported) context.tr('文件'),
    ];
    return parts.isEmpty ? context.tr('无') : parts.join(', ');
  }
}
