import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../rdp/key_mapping.dart';
import '../rdp/rdp_session.dart';
import '../rdp/session_recovery.dart';
import '../rdp/session_issue.dart';
import '../rdp/frame_rate.dart';
import 'transfer_dialog.dart';
import 'adaptive.dart';
import 'remote_surface.dart';
import 'remote_view_memory.dart';
import 'mobile_keyboard.dart';

class RemoteView extends StatefulWidget {
  const RemoteView({
    super.key,
    required this.session,
    required this.reconnect,
    required this.disconnect,
    required this.active,
    required this.toggleFullscreen,
    this.fullscreen = false,
    this.recovery,
    this.configure,
    this.memory,
    this.frameRateLimit = 0,
  });
  final RdpSession session;
  final RemoteViewMemory? memory;
  final SessionRecovery? recovery;
  final VoidCallback? configure;
  final VoidCallback reconnect, disconnect, toggleFullscreen;
  final bool active, fullscreen;
  final int frameRateLimit;
  @override
  State<RemoteView> createState() => _RemoteViewState();
}

class _RemoteViewState extends State<RemoteView> with WidgetsBindingObserver {
  final _focus = FocusNode();
  final _transform = TransformationController();
  late final _memory = widget.memory ?? RemoteViewMemory();
  final _pressed = <int>{};
  Timer? _clipboardTimer;
  String? _lastClipboard;
  bool get _pan => _memory.pan;
  set _pan(bool value) => _memory.pan = value;
  bool get _trackpad => _memory.trackpad ?? false;
  set _trackpad(bool value) => _memory.trackpad = value;
  bool _keyboard = false;
  final _displayToken = DisplayRefresh.allocate();
  (bool, int)? _displayRequest;
  RdpSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_updateDisplayRequest);
    _focus.addListener(_focusChanged);
    _clipboardTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _syncClipboard(),
    );
  }

  @override
  void didUpdateWidget(covariant RemoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != session) {
      oldWidget.session.removeListener(_updateDisplayRequest);
      session.addListener(_updateDisplayRequest);
    }
    _updateFrameRate();
    if (!widget.active) {
      _releaseKeys();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateFrameRate();
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateFrameRate();
    });
  }

  void _updateFrameRate() {
    session.setFrameRate(
      FrameRatePolicy.effective(
        View.of(context).display.refreshRate,
        widget.frameRateLimit,
      ),
    );
    _updateDisplayRequest();
  }

  void _updateDisplayRequest() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final active =
        widget.active &&
        session.isActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    final request = (active, widget.frameRateLimit);
    if (_displayRequest == request) return;
    _displayRequest = request;
    unawaited(
      DisplayRefresh.request(
        _displayToken,
        active: active,
        limit: widget.frameRateLimit,
      ),
    );
  }

  void _focusChanged() {
    if (!_focus.hasFocus) {
      _releaseKeys();
    } else {
      final locks = HardwareKeyboard.instance.lockModesEnabled;
      session.input(
        4,
        (locks.contains(KeyboardLockMode.scrollLock) ? 1 : 0) |
            (locks.contains(KeyboardLockMode.numLock) ? 2 : 0) |
            (locks.contains(KeyboardLockMode.capsLock) ? 4 : 0),
      );
    }
  }

  void _releaseKeys() {
    for (final code in _pressed) {
      session.scan(code, false);
    }
    _pressed.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseKeys();
    _updateDisplayRequest();
  }

  Future<void> _syncClipboard({bool manual = false}) async {
    if (!mounted ||
        !widget.active ||
        !session.profile.clipboard ||
        !session.clipboardSupported ||
        session.pasteInProgress ||
        session.state != SessionState.connected ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      if (session.remoteClipboard != null) {
        _lastClipboard = session.remoteClipboard;
        session.remoteClipboard = null;
        await Clipboard.setData(ClipboardData(text: _lastClipboard!));
      } else if (manual ||
          (_focus.hasFocus &&
              {
                TargetPlatform.linux,
                TargetPlatform.windows,
                TargetPlatform.macOS,
              }.contains(Theme.of(context).platform))) {
        final text = (await Clipboard.getData('text/plain'))?.text;
        if (text != null &&
            text != _lastClipboard &&
            text.length <= 256 * 1024 &&
            mounted &&
            widget.active) {
          _lastClipboard = text;
          session.clipboard(text);
        }
      }
    } on PlatformException {
      /* Clipboard access can be denied by the OS. */
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_updateDisplayRequest);
    unawaited(DisplayRefresh.request(_displayToken, active: false, limit: 0));
    _clipboardTimer?.cancel();
    _releaseKeys();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _transform.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.active || session.state != SessionState.connected) {
      return KeyEventResult.ignored;
    }
    // Ctrl+Alt+Home always returns keyboard control to the local toolbar.
    if (event.logicalKey == LogicalKeyboardKey.home &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    final scan = rdpScancode(event.physicalKey);
    if (scan == null) return KeyEventResult.ignored;
    final down = event is! KeyUpEvent;
    if (down) {
      _pressed.add(scan);
    } else {
      _pressed.remove(scan);
    }
    session.scan(scan, down);
    return KeyEventResult.handled;
  }

  Future<void> _sendText() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送文字'),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        content: SizedBox(
          width: 520,
          child: MobileKeyboard(
            session: session,
            shortcuts: false,
            simulateKeys: _memory.keyboardSimulation,
            pasteText: _memory.pasteText,
            onPasteTextChanged: (paste) => _memory.pasteText = paste,
            onModeChanged: (keys) => _memory.keyboardSimulation = keys,
            close: () => Navigator.pop(context),
          ),
        ),
      ),
    );
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, widget.recovery]),
    builder: (context, _) {
      final connected = session.state == SessionState.connected;
      final phone = phoneLayout(context);
      _memory.trackpad ??= phone;
      return LayoutBuilder(
        builder: (context, bounds) => Column(
          children: [
            if (!phone)
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: SizedBox(
                  height: 54,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      _tool(
                        connected ? Icons.circle : Icons.circle_outlined,
                        connected ? '已连接' : '会话状态',
                        null,
                        color: connected ? const Color(0xFF3B9B73) : null,
                      ),
                      const VerticalDivider(indent: 16, endIndent: 16),
                      _tool(
                        Icons.keyboard_outlined,
                        '发送文字',
                        connected ? _sendText : null,
                      ),
                      _tool(
                        Icons.content_paste_outlined,
                        '同步剪贴板',
                        connected && session.clipboardSupported
                            ? () => _syncClipboard(manual: true)
                            : null,
                      ),
                      _tool(
                        Icons.folder_copy_outlined,
                        session.profile.fileTransfer
                            ? '文件中转站'
                            : '请在连接偏好开启文件传输后重新连接',
                        session.transferDirectory == null
                            ? null
                            : () => showTransfers(context, session),
                      ),
                      _tool(
                        Icons.security_outlined,
                        'Ctrl + Alt + Del',
                        connected
                            ? () => session.chord([0x1d, 0x38, 0x153])
                            : null,
                      ),
                      _tool(
                        Icons.window,
                        'Windows 键',
                        connected ? () => session.chord([0x15b]) : null,
                      ),
                      _tool(
                        _trackpad
                            ? Icons.touch_app_outlined
                            : Icons.mouse_outlined,
                        _trackpad ? '触控板模式' : '直接触控',
                        () => setState(() => _trackpad = !_trackpad),
                      ),
                      _tool(
                        _pan ? Icons.pan_tool_alt_outlined : Icons.ads_click,
                        _pan ? '平移画面' : '控制电脑',
                        () => setState(() => _pan = !_pan),
                      ),
                      _tool(
                        Icons.fit_screen,
                        '适应窗口',
                        () => _transform.value = Matrix4.identity(),
                      ),
                      _tool(
                        Icons.aspect_ratio,
                        session.displayResizeSupported
                            ? '匹配窗口分辨率'
                            : '服务器未开放动态分辨率',
                        connected && session.displayResizeSupported
                            ? () {
                                final size = MediaQuery.sizeOf(context);
                                session.resize(
                                  size.width.round(),
                                  (size.height - 150).round(),
                                );
                              }
                            : null,
                      ),
                      _tool(
                        widget.fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        '专注模式',
                        widget.toggleFullscreen,
                      ),
                      _tool(
                        Icons.power_settings_new,
                        '断开连接',
                        widget.disconnect,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Material(
                color: const Color(0xFF0C1512),
                child: connected && session.hasVideo
                    ? TextFieldTapRegion(
                        enabled: phone && _keyboard,
                        child: Focus(
                          focusNode: _focus,
                          onKeyEvent: _key,
                          child: RemoteSurface(
                            session: session,
                            focus: _focus,
                            transform: _transform,
                            trackpad: _trackpad,
                            pan: _pan,
                            active: widget.active,
                            preserveKeyboardFocus: phone && _keyboard,
                            memory: _memory.surface,
                          ),
                        ),
                      )
                    : _status(context),
              ),
            ),
            if (!phone)
              Container(
                height: 30,
                color: const Color(0xFF13231C),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      color: Color(0xFFA4B6AC),
                      size: 12,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${session.profile.address}  ·  ${session.profile.nla ? 'NLA / TLS' : 'TLS'}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFA4B6AC),
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (session.hasVideo)
                      Text(
                        '${session.desktopWidth} × ${session.desktopHeight}',
                        style: const TextStyle(
                          color: Color(0xFFA4B6AC),
                          fontSize: 11,
                        ),
                      ),
                    if (MediaQuery.sizeOf(context).width > 650)
                      const Text(
                        '    Ctrl + Alt + Home 释放键盘',
                        style: TextStyle(
                          color: Color(0xFFA4B6AC),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            if (phone && _keyboard && connected)
              // Large text and an IME can leave less room than a composer plus
              // its error needs. Scroll locally so every control stays reachable.
              ConstrainedBox(
                constraints: BoxConstraints(
                  // Keep a touchable desktop above even a large error panel.
                  maxHeight:
                      bounds.maxHeight - math.min(72, bounds.maxHeight * .35),
                ),
                child: SingleChildScrollView(
                  primary: false,
                  child: MobileKeyboard(
                    session: session,
                    simulateKeys: _memory.keyboardSimulation,
                    pasteText: _memory.pasteText,
                    onPasteTextChanged: (paste) => _memory.pasteText = paste,
                    onModeChanged: (keys) => _memory.keyboardSimulation = keys,
                    shortcuts: bounds.maxHeight > 320,
                    close: () {
                      FocusScope.of(context).unfocus();
                      setState(() => _keyboard = false);
                    },
                  ),
                ),
              )
            else if (phone)
              _phoneDock(connected),
          ],
        ),
      );
    },
  );

  Widget _phoneDock(bool connected) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Row(
      children: [
        _dockItem(
          Icons.keyboard_outlined,
          '键盘',
          connected ? () => setState(() => _keyboard = true) : null,
        ),
        _dockItem(
          _trackpad ? Icons.mouse_outlined : Icons.touch_app_outlined,
          _trackpad ? '触控板' : '触屏',
          () => setState(() {
            _trackpad = !_trackpad;
            _pan = false;
          }),
        ),
        _dockItem(
          _pan ? Icons.pan_tool_outlined : Icons.pinch_outlined,
          _pan ? '移动画面' : '缩放',
          () {
            setState(() => _pan = !_pan);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_pan ? '单指移动画面，双指捏合缩放；再次点按可控制电脑' : '已返回远程控制'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
          selected: _pan,
        ),
        _dockItem(Icons.folder_outlined, '文件', () {
          if (session.transferDirectory != null) {
            showTransfers(context, session);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请在编辑连接 → 连接偏好开启文件传输，然后重新连接')),
            );
          }
        }),
        _dockItem(Icons.more_horiz, '更多', _phoneMore),
      ],
    ),
  );

  Widget _dockItem(
    IconData icon,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) => Expanded(
    child: Semantics(
      button: true,
      enabled: action != null,
      selected: selected,
      child: InkWell(
        onTap: action,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: action == null
                      ? Theme.of(context).disabledColor
                      : selected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: action == null
                        ? Theme.of(context).disabledColor
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _phoneMore() async {
    final connected = session.state == SessionState.connected;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                '${session.profile.address}  ·  ${session.hasVideo ? session.desktopWidth : session.profile.width} × ${session.hasVideo ? session.desktopHeight : session.profile.height}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final entry in <String, (IconData, String, bool)>{
              'fit': (Icons.fit_screen, '适应屏幕', true),
              'resize': (
                Icons.aspect_ratio,
                '匹配手机分辨率',
                connected && session.displayResizeSupported,
              ),
              'clipboard': (
                Icons.content_paste_outlined,
                '同步剪贴板',
                connected && session.clipboardSupported,
              ),
              'cad': (Icons.security_outlined, 'Ctrl + Alt + Del', connected),
              'win': (Icons.window, 'Windows 键', connected),
              'help': (Icons.gesture_outlined, '触控手势说明', true),
              'disconnect': (Icons.power_settings_new, '断开连接', true),
            }.entries)
              ListTile(
                minTileHeight: 56,
                leading: Icon(entry.value.$1),
                title: Text(entry.value.$2),
                enabled: entry.value.$3,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'fit':
        _transform.value = Matrix4.identity();
        setState(() => _pan = false);
      case 'resize':
        final size = MediaQuery.sizeOf(context);
        session.resize(
          size.width.round(),
          (size.height - MediaQuery.paddingOf(context).vertical - 120).round(),
        );
      case 'clipboard':
        await _syncClipboard(manual: true);
      case 'cad':
        session.chord([0x1d, 0x38, 0x153]);
      case 'win':
        session.chord([0x15b]);
      case 'disconnect':
        widget.disconnect();
      case 'help':
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          useSafeArea: true,
          builder: (context) => const SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text(
                '触控板：单指移动光标，轻点左键。\n触屏：轻点画面上的位置。\n双指轻点或长按后松开：鼠标右键。\n双击后按住并移动：拖拽，松手结束。\n双指上下或左右滑动：滚动页面。\n双指捏合：缩放画面。\n放大后光标靠近边缘：自动移动视野。\n缩放按钮：切换为单指移动画面。\n键盘：本机输入法选词后点发送；上方有常用快捷键。\n返回列表会保持当前连接、缩放位置和操作模式。',
                style: TextStyle(fontSize: 15, height: 2),
              ),
            ),
          ),
        );
    }
  }

  Widget _tool(
    IconData icon,
    String label,
    VoidCallback? callback, {
    Color? color,
  }) => Tooltip(
    message: label,
    child: TextButton.icon(
      onPressed: callback,
      icon: Icon(icon, size: 17, color: color),
      label: Text(label, style: TextStyle(fontSize: 12, color: color)),
    ),
  );

  Widget _status(BuildContext context) {
    final recovery = widget.recovery;
    final issue = SessionIssue.from(session);
    final recovering =
        recovery != null &&
        (recovery.pending || recovery.running || recovery.suspended);
    final waiting =
        session.state == SessionState.connecting ||
        session.state == SessionState.connected;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (waiting || recovering)
              const CircularProgressIndicator(color: Color(0xFFBDE3C9))
            else
              const Icon(
                Icons.desktop_access_disabled_outlined,
                size: 52,
                color: Color(0xFFBDE3C9),
              ),
            const SizedBox(height: 24),
            Text(
              recovering
                  ? (recovery.suspended
                        ? '回到应用后继续重连'
                        : recovery.pending
                        ? '网络中断，${recovery.remainingSeconds} 秒后重连'
                        : '正在重新连接…')
                  : waiting
                  ? (session.state == SessionState.connecting
                        ? '正在建立安全连接…'
                        : '等待远程画面…')
                  : issue.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              waiting ? session.profile.address : issue.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFACBEB3), fontSize: 13),
            ),
            if (recovering) ...[
              const SizedBox(height: 12),
              Text(
                '第 ${recovery.attempts + (recovery.pending || recovery.suspended ? 1 : 0)} / ${SessionRecovery.maxAttempts} 次重试',
                style: const TextStyle(color: Color(0xFFACBEB3)),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (recovery.pending)
                    FilledButton.icon(
                      onPressed: recovery.retryNow,
                      icon: const Icon(Icons.refresh),
                      label: const Text('立即重连'),
                    ),
                  OutlinedButton(
                    onPressed: recovery.cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('取消重连'),
                  ),
                ],
              ),
            ] else if (!waiting) ...[
              if (recovery?.exhausted ?? false) ...[
                const SizedBox(height: 12),
                const Text(
                  '自动重连已达上限，请检查网络后重试',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFACBEB3)),
                ),
              ],
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: issue.action == SessionAction.settings
                        ? widget.configure ?? widget.reconnect
                        : widget.reconnect,
                    icon: Icon(
                      issue.action == SessionAction.credentials
                          ? Icons.login
                          : Icons.refresh,
                    ),
                    label: Text(issue.actionLabel),
                  ),
                  if (widget.configure != null &&
                      issue.action != SessionAction.settings)
                    OutlinedButton(
                      onPressed: widget.configure,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('编辑连接'),
                    ),
                ],
              ),
              if (session.endReason != SessionEndReason.local &&
                  (session.error.isNotEmpty || session.errorCode != 0)) ...[
                const SizedBox(height: 16),
                ExpansionTile(
                  key: const Key('connectionDiagnostics'),
                  title: const Text(
                    '技术详情',
                    style: TextStyle(color: Color(0xFFACBEB3), fontSize: 13),
                  ),
                  iconColor: const Color(0xFFACBEB3),
                  collapsedIconColor: const Color(0xFFACBEB3),
                  children: [
                    SelectableText(
                      '${session.profile.address}\n代码：0x${session.errorCode.toRadixString(16).padLeft(8, '0')}\n${session.error.length > 4096 ? session.error.substring(0, 4096) : session.error}',
                      style: const TextStyle(
                        color: Color(0xFFACBEB3),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
