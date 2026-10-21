import '../l10n/app_strings.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import '../rdp/clipboard_picture.dart';
import '../rdp/key_mapping.dart';
import '../rdp/rdp_session.dart';
import '../rdp/session_recovery.dart';
import '../rdp/session_issue.dart';
import '../rdp/frame_rate.dart';
import '../models/remote_input_mode.dart';
import 'transfer_dialog.dart';
import 'adaptive.dart';
import 'remote_surface.dart';
import 'remote_view_memory.dart';
import 'mobile_keyboard.dart';
import 'floating_controls.dart';
import 'image_clipboard.dart';

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
    this.leave,
    this.onInputModeChanged,
  });
  final RdpSession session;
  final RemoteViewMemory? memory;
  final SessionRecovery? recovery;
  final VoidCallback? configure;
  final VoidCallback reconnect, disconnect, toggleFullscreen;
  final bool active, fullscreen;
  final int frameRateLimit;
  final VoidCallback? leave;
  final ValueChanged<RemoteInputMode>? onInputModeChanged;
  @override
  State<RemoteView> createState() => _RemoteViewState();
}

class _RemoteViewState extends State<RemoteView> with WidgetsBindingObserver {
  final _focus = FocusNode();
  final _localFocus = FocusNode();
  final _transform = TransformationController();
  late final _memory = widget.memory ?? RemoteViewMemory();
  final _pressed = <int>{};
  Timer? _clipboardTimer;
  String? _lastClipboard;
  bool _clipboardBusy = false;
  bool get _pan => _memory.pan;
  set _pan(bool value) => _memory.pan = value;
  bool get _trackpad => _memory.trackpad ?? false;
  set _trackpad(bool value) => _memory.trackpad = value;
  bool _keyboard = false;
  bool _localControl = false;
  final _localShortcutKeys = <PhysicalKeyboardKey>{};
  bool _controlsBeforeKeyboard = false;
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
      _localShortcutKeys.clear();
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
    if (state != AppLifecycleState.resumed) {
      _localShortcutKeys.clear();
      _releaseKeys();
    }
    _updateDisplayRequest();
  }

  Future<void> _syncClipboard({bool manual = false}) async {
    if (!mounted ||
        !widget.active ||
        !session.profile.clipboard ||
        !session.clipboardSupported ||
        _clipboardBusy ||
        session.pasteInProgress ||
        session.state != SessionState.connected ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final target = session;
    final connection = target.connectedAt;
    bool current() =>
        mounted &&
        widget.active &&
        identical(session, target) &&
        target.state == SessionState.connected &&
        target.connectedAt == connection;
    _clipboardBusy = true;
    try {
      if (target.remotePicture case final pending?) {
        var consumed = false;
        try {
          final picture = await ClipboardPicture.decode(
            pending.bytes,
            kind: pending.kind,
          );
          if (current() &&
              target.remotePicture == pending &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed) {
            consumed = await ImageClipboard.write(
              picture,
              isCurrent: () =>
                  current() &&
                  target.remotePicture == pending &&
                  WidgetsBinding.instance.lifecycleState ==
                      AppLifecycleState.resumed,
            );
            if (consumed) _lastClipboard = null;
          }
        } on Exception {
          consumed = true;
          rethrow;
        } finally {
          if (consumed && target.remotePicture == pending) {
            target.discardRemotePicture();
          }
        }
      } else if (session.remoteClipboard != null) {
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
    } on MissingPluginException {
      /* Older platform runners can still use text clipboard operations. */
    } on Exception {
      /* Invalid image encodings never replace the system clipboard. */
    } finally {
      _clipboardBusy = false;
    }
  }

  Future<void> _pasteLocalClipboard() async {
    if (_clipboardBusy || session.pasteInProgress) return;
    _clipboardBusy = true;
    String message;
    try {
      final text = (await Clipboard.getData('text/plain'))?.text;
      if (!mounted ||
          !widget.active ||
          session.state != SessionState.connected) {
        return;
      }
      if (text == null || text.isEmpty) {
        message = context.tr('本机剪贴板没有文字；可使用“粘贴本机图片”或“选择文件粘贴”');
      } else {
        // A user-requested local paste takes priority over a pending remote
        // update. Never replace the local payload with remote clipboard text.
        session.remoteClipboard = null;
        session.discardRemotePicture();
        _lastClipboard = text;
        final sent = await session.paste(text);
        if (!mounted) return;
        message = sent
            ? context.tr('已向远程电脑发送粘贴，请确认目标输入框已获得焦点')
            : context.tr(session.pasteError);
      }
    } on PlatformException {
      if (!mounted) return;
      message = context.tr('无法读取本机剪贴板，请检查系统权限后重试');
    } finally {
      _clipboardBusy = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pastePicture({bool fromFile = false}) async {
    if (_clipboardBusy ||
        session.pasteInProgress ||
        !session.profile.clipboard ||
        !session.imageClipboardSupported) {
      return;
    }
    final target = session;
    final connection = target.connectedAt;
    final desktop = {
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }.contains(Theme.of(context).platform);
    bool current() =>
        mounted &&
        widget.active &&
        identical(session, target) &&
        target.state == SessionState.connected &&
        target.connectedAt == connection;
    _clipboardBusy = true;
    String? message;
    try {
      // Preserve the local text snapshot so the automatic text poll does not
      // immediately replace an image published by this explicit operation.
      if (desktop) {
        try {
          _lastClipboard = (await Clipboard.getData(
            Clipboard.kTextPlain,
          ))?.text;
        } on PlatformException {
          /* Text permission need not block image selection. */
        }
      }
      if (!current() || !mounted) return;
      ClipboardPicture? picture;
      if (fromFile) {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: context.tr('图片'),
              extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
              mimeTypes: [
                'image/png',
                'image/jpeg',
                'image/webp',
                'image/bmp',
                'image/gif',
              ],
              uniformTypeIdentifiers: ['public.image'],
            ),
          ],
        );
        if (file == null || !current()) return;
        if (await file.length() > ClipboardPicture.maxBytes) {
          throw const FormatException('图片数据最大 16 MiB');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final block in file.openRead()) {
          if (bytes.length + block.length > ClipboardPicture.maxBytes) {
            throw const FormatException('图片数据最大 16 MiB');
          }
          bytes.add(block);
        }
        picture = await ClipboardPicture.decode(bytes.takeBytes());
      } else {
        picture = await ImageClipboard.read();
      }
      if (!current() || !mounted) return;
      if (picture == null) {
        message = context.tr('本机剪贴板没有图片，可使用“选择图片粘贴”');
      } else {
        target.remoteClipboard = null;
        target.discardRemotePicture();
        final sent = await target.pastePicture(picture);
        if (!current() || !mounted) return;
        message = context.tr(
          sent ? '图片已传输并发送粘贴，请在远程应用中确认' : '图片未确认送达，请确认服务端和目标应用支持图片粘贴',
        );
      }
    } on FormatException catch (e) {
      if (mounted) message = context.tr(e.message.toString());
    } on Exception {
      if (mounted) message = context.tr('无法读取图片，请检查剪贴板权限或选择图片文件');
    } finally {
      _clipboardBusy = false;
    }
    if (mounted && widget.active && message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _pasteFiles() async {
    if (_clipboardBusy ||
        session.pasteInProgress ||
        !session.profile.clipboard ||
        !session.fileClipboardSupported) {
      return;
    }
    final target = session;
    final connection = target.connectedAt;
    bool current() =>
        mounted &&
        widget.active &&
        identical(session, target) &&
        target.state == SessionState.connected &&
        target.connectedAt == connection;
    _clipboardBusy = true;
    String? message;
    try {
      final desktop = {
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }.contains(Theme.of(context).platform);
      if (desktop) {
        try {
          _lastClipboard = (await Clipboard.getData(
            Clipboard.kTextPlain,
          ))?.text;
        } on PlatformException {
          /* Selecting a file does not require reading the text clipboard. */
        }
      }
      if (!current()) return;
      final files = await openFiles();
      if (files.isEmpty || !current() || !mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('正在准备文件…'))));
      final sent = await target.pasteFiles(files);
      if (!current() || !mounted) return;
      message = context.tr(
        sent
            ? '已发送文件粘贴请求，请保持连接并在远端确认复制完成'
            : target.pasteError.isNotEmpty
            ? target.pasteError
            : '文件粘贴未完成，可使用文件中转站',
      );
    } on Exception {
      if (current() && mounted) message = context.tr('无法准备文件，请重新选择');
    } finally {
      _clipboardBusy = false;
    }
    if (current() && mounted && message != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
          ),
        );
    }
  }

  @override
  void dispose() {
    if (_keyboard) _memory.controlsCollapsed = _controlsBeforeKeyboard;
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_updateDisplayRequest);
    unawaited(DisplayRefresh.request(_displayToken, active: false, limit: 0));
    _clipboardTimer?.cancel();
    _releaseKeys();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _localFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _returnLocal() {
    _releaseKeys();
    _localFocus.requestFocus();
    setState(() {
      _localControl = true;
      _memory.controlsCollapsed = false;
    });
  }

  void _resumeRemote() {
    setState(() => _localControl = false);
    _focus.requestFocus();
  }

  KeyEventResult _shortcut(FocusNode node, KeyEvent event) {
    if (!widget.active) return KeyEventResult.ignored;
    if (_localShortcutKeys.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _localShortcutKeys.remove(event.physicalKey);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        keyboard.isAltPressed &&
        (event.logicalKey == LogicalKeyboardKey.home ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      if (event is KeyDownEvent) {
        _localShortcutKeys.add(event.physicalKey);
        _returnLocal();
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          widget.toggleFullscreen();
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _inputModeChanged(RemoteInputMode mode) {
    _memory.mode = mode;
    widget.onInputModeChanged?.call(mode);
  }

  void _hideKeyboard() {
    FocusScope.of(context).unfocus();
    setState(() {
      _keyboard = false;
      _memory.controlsCollapsed = _localControl
          ? false
          : _controlsBeforeKeyboard;
    });
    if (_localControl) _localFocus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final shortcut = _shortcut(node, event);
    if (shortcut == KeyEventResult.handled) return shortcut;
    if (!widget.active ||
        _localControl ||
        session.state != SessionState.connected) {
      return KeyEventResult.ignored;
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
        title: Text(context.tr("发送文字")),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        content: SizedBox(
          width: 520,
          child: MobileKeyboard(
            session: session,
            shortcuts: false,
            simulateKeys: _memory.keyboardSimulation,
            initialModifierLock: _memory.modifierLock,
            onModifierLockChanged: (value) => _memory.modifierLock = value,
            pasteText: _memory.pasteText,
            onInputModeChanged: _inputModeChanged,
            initialDraft: _memory.textDraft,
            onDraftChanged: (draft) => _memory.textDraft = draft,
            onSessionShortcut: (event) {
              final result = _shortcut(_localFocus, event);
              if (result == KeyEventResult.handled && event is KeyDownEvent) {
                Navigator.pop(context);
              }
              return result;
            },
            close: () => Navigator.pop(context),
          ),
        ),
      ),
    );
    if (mounted && !_localControl) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _localFocus,
    onKeyEvent: _shortcut,
    child: ListenableBuilder(
      listenable: Listenable.merge([session, widget.recovery]),
      builder: (context, _) {
        final connected = session.state == SessionState.connected;
        final phone = phoneLayout(context);
        final desktop = {
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.macOS,
        }.contains(Theme.of(context).platform);
        _memory.trackpad ??= phone;
        return LayoutBuilder(
          builder: (context, bounds) => Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, viewport) {
                    if (widget.active &&
                        !_keyboard &&
                        MediaQuery.viewInsetsOf(context).bottom == 0) {
                      session.setViewportSize(
                        viewport.maxWidth.round(),
                        viewport.maxHeight.round(),
                      );
                    }
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Listener(
                          onPointerDown: _localControl
                              ? (_) => _resumeRemote()
                              : null,
                          child: Material(
                            color: const Color(0xFF0C1512),
                            child: connected && session.hasVideo
                                ? TextFieldTapRegion(
                                    enabled: phone && _keyboard,
                                    child: Focus(
                                      focusNode: _focus,
                                      skipTraversal: _localControl,
                                      onKeyEvent: _key,
                                      child: RemoteSurface(
                                        session: session,
                                        focus: _focus,
                                        transform: _transform,
                                        trackpad: _trackpad,
                                        pan: _pan,
                                        active: widget.active,
                                        inputEnabled: !_localControl,
                                        preserveKeyboardFocus:
                                            phone && _keyboard,
                                        memory: _memory.surface,
                                      ),
                                    ),
                                  )
                                : _status(context),
                          ),
                        ),
                        TextFieldTapRegion(
                          enabled: phone && _keyboard,
                          child: FloatingControls(
                            memory: _memory,
                            title: session.profile.name,
                            actions: [
                              _action(
                                Icons.arrow_back,
                                context.tr("电脑列表"),
                                widget.leave,
                                tooltip: context.tr("返回电脑列表（保持连接）"),
                              ),
                              _action(
                                Icons.keyboard_outlined,
                                context.tr("键盘"),
                                connected
                                    ? () {
                                        if (phone) {
                                          setState(() {
                                            _controlsBeforeKeyboard =
                                                _memory.controlsCollapsed;
                                            _keyboard = true;
                                            _memory.controlsCollapsed = true;
                                          });
                                        } else {
                                          _sendText();
                                        }
                                      }
                                    : null,
                              ),
                              _action(
                                _trackpad
                                    ? Icons.mouse_outlined
                                    : Icons.touch_app_outlined,
                                _trackpad
                                    ? context.tr("触控板")
                                    : context.tr("触屏"),
                                () => setState(() {
                                  _trackpad = !_trackpad;
                                  _pan = false;
                                }),
                              ),
                              _action(
                                _pan
                                    ? Icons.pan_tool_outlined
                                    : Icons.pinch_outlined,
                                _pan ? context.tr("控制电脑") : context.tr("移动画面"),
                                () => setState(() => _pan = !_pan),
                              ),
                              _action(Icons.fit_screen, context.tr("适应屏幕"), () {
                                _transform.value = Matrix4.identity();
                                setState(() => _pan = false);
                              }),
                              _action(
                                widget.fullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                widget.fullscreen
                                    ? context.tr("退出全屏")
                                    : context.tr("全屏"),
                                widget.toggleFullscreen,
                              ),
                              _action(
                                Icons.more_horiz,
                                context.tr("更多"),
                                _phoneMore,
                              ),
                            ],
                          ),
                        ),
                        if (desktop && widget.fullscreen)
                          Positioned(
                            top: MediaQuery.paddingOf(context).top + 8,
                            left: MediaQuery.paddingOf(context).left + 8,
                            child: Material(
                              key: const Key('fullscreenControlHint'),
                              elevation: 3,
                              borderRadius: BorderRadius.circular(12),
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.min(
                                    480,
                                    viewport.maxWidth - 16,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Tooltip(
                                        message: _localControl
                                            ? context.tr('点击远程画面继续控制')
                                            : 'Ctrl + Alt + Home',
                                        child: TextButton.icon(
                                          key: const Key(
                                            'releaseSessionControl',
                                          ),
                                          onPressed: _localControl
                                              ? _resumeRemote
                                              : _returnLocal,
                                          icon: Icon(
                                            _localControl
                                                ? Icons.mouse_outlined
                                                : Icons.lock_open_outlined,
                                          ),
                                          label: Text(
                                            context.tr(
                                              _localControl ? '继续控制' : '释放控制',
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (!_localControl)
                                      const Flexible(
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: Text('Ctrl + Alt + Home'),
                                        ),
                                      ),
                                    IconButton(
                                      key: const Key('exitSessionFullscreen'),
                                      tooltip: context.tr(
                                        '退出全屏（Ctrl + Alt + Enter）',
                                      ),
                                      onPressed: () {
                                        _returnLocal();
                                        widget.toggleFullscreen();
                                      },
                                      icon: const Icon(Icons.fullscreen_exit),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (phone && _keyboard && connected)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        bounds.maxHeight - math.min(72, bounds.maxHeight * .35),
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: SafeArea(
                      top: false,
                      child: MobileKeyboard(
                        session: session,
                        simulateKeys: _memory.keyboardSimulation,
                        initialModifierLock: _memory.modifierLock,
                        onModifierLockChanged: (value) =>
                            _memory.modifierLock = value,
                        pasteText: _memory.pasteText,
                        onInputModeChanged: _inputModeChanged,
                        initialDraft: _memory.textDraft,
                        onDraftChanged: (draft) => _memory.textDraft = draft,
                        onSessionShortcut: (event) {
                          final result = _shortcut(_localFocus, event);
                          if (result == KeyEventResult.handled &&
                              event is KeyDownEvent) {
                            _hideKeyboard();
                          }
                          return result;
                        },
                        shortcuts: false,
                        close: _hideKeyboard,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _action(
    IconData icon,
    String label,
    VoidCallback? callback, {
    String? tooltip,
  }) => SizedBox(
    width: 68,
    child: Tooltip(
      message: tooltip ?? label,
      child: TextButton(
        onPressed: callback,
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 64),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 23),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  String? get _filePasteUnavailableReason {
    if (session.state != SessionState.connected) return '连接成功后才能粘贴文件';
    if (!session.profile.clipboard) {
      return '请在连接偏好中开启“共享剪贴板”，然后重新连接';
    }
    if (!session.clipboardSupported) {
      return '剪贴板尚未就绪，请稍候；若持续不可用，请检查服务端设置';
    }
    if (!session.fileClipboardSupported) {
      return '当前连接未启用文件剪贴板，请检查服务端设置或尝试文件中转站';
    }
    if (session.pasteInProgress) return '正在处理粘贴，请完成后重试';
    return null;
  }

  Future<void> _phoneMore() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final connected = session.state == SessionState.connected;
          final filePasteUnavailableReason = _filePasteUnavailableReason;
          return SafeArea(
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
                    '匹配画面分辨率',
                    connected && session.displayResizeSupported,
                  ),
                  'files': (
                    Icons.folder_outlined,
                    '文件中转站',
                    session.transferDirectory != null,
                  ),
                  'clipboard': (
                    Icons.content_paste_outlined,
                    '同步剪贴板',
                    connected && session.clipboardSupported,
                  ),
                  'paste': (
                    Icons.content_paste_go_outlined,
                    '粘贴本机文字',
                    connected &&
                        session.profile.clipboard &&
                        session.clipboardSupported &&
                        !session.pasteInProgress,
                  ),
                  'pasteImage': (
                    Icons.image_outlined,
                    '粘贴本机图片',
                    connected &&
                        session.profile.clipboard &&
                        session.imageClipboardSupported &&
                        !session.pasteInProgress,
                  ),
                  'imageFile': (
                    Icons.add_photo_alternate_outlined,
                    '选择图片粘贴',
                    connected &&
                        session.profile.clipboard &&
                        session.imageClipboardSupported &&
                        !session.pasteInProgress,
                  ),
                  'pasteFiles': (
                    Icons.upload_file_outlined,
                    '选择文件粘贴',
                    filePasteUnavailableReason == null,
                  ),
                  'cad': (
                    Icons.security_outlined,
                    'Ctrl + Alt + Del',
                    connected,
                  ),
                  'win': (Icons.window, 'Windows 键', connected),
                  'help': (Icons.gesture_outlined, '触控手势说明', true),
                  'disconnect': (Icons.power_settings_new, '断开连接', true),
                }.entries)
                  ListTile(
                    minTileHeight: 56,
                    leading: Icon(entry.value.$1),
                    title: Text(context.tr(entry.value.$2)),
                    subtitle: entry.key == 'pasteFiles'
                        ? Text(
                            context.tr(
                              filePasteUnavailableReason ??
                                  '先在远端打开目标文件夹；每次最多 32 个文件',
                            ),
                          )
                        : null,
                    enabled: entry.value.$3,
                    onTap: () => Navigator.pop(context, entry.key),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'fit':
        _transform.value = Matrix4.identity();
        setState(() => _pan = false);
      case 'resize':
        session.matchViewportResolution();
      case 'files':
        await showTransfers(context, session);
      case 'clipboard':
        await _syncClipboard(manual: true);
      case 'paste':
        await _pasteLocalClipboard();
      case 'pasteImage':
        await _pastePicture();
      case 'imageFile':
        await _pastePicture(fromFile: true);
      case 'pasteFiles':
        await _pasteFiles();
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
          builder: (context) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text(
                context.tr(
                  "触控板：单指移动光标，轻点左键。\n触屏：轻点画面上的位置。\n双指轻点或长按后松开：鼠标右键。\n双击后按住并移动：拖拽，松手结束。\n双指上下或左右滑动：滚动页面。\n双指捏合：缩放画面。\n放大后光标靠近边缘：自动移动视野。\n移动画面按钮：切换为单指移动画面。\n键盘：默认模拟按键；可切换文字或粘贴输入，上方有特殊按键。\n返回列表会保持当前连接、缩放位置和操作模式。",
                ),
                style: TextStyle(fontSize: 15, height: 2),
              ),
            ),
          ),
        );
    }
  }

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
                        ? context.tr("回到应用后继续重连")
                        : recovery.pending
                        ? context.tr("网络中断，{0} 秒后重连", [
                            recovery.remainingSeconds,
                          ])
                        : context.tr("正在重新连接…"))
                  : waiting
                  ? (session.state == SessionState.connecting
                        ? context.tr("正在建立安全连接…")
                        : context.tr("等待远程画面…"))
                  : context.tr(issue.title),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              waiting ? session.profile.address : context.tr(issue.message),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFACBEB3), fontSize: 13),
            ),
            if (recovering) ...[
              const SizedBox(height: 12),
              Text(
                context.tr("第 {0} / {1} 次重试", [
                  recovery.attempts +
                      (recovery.pending || recovery.suspended ? 1 : 0),
                  SessionRecovery.maxAttempts,
                ]),
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
                      label: Text(context.tr("立即重连")),
                    ),
                  OutlinedButton(
                    onPressed: recovery.cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: Text(context.tr("取消重连")),
                  ),
                ],
              ),
            ] else if (!waiting) ...[
              if (recovery?.exhausted ?? false) ...[
                const SizedBox(height: 12),
                Text(
                  context.tr("自动重连已达上限，请检查网络后重试"),
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
                    label: Text(context.tr(issue.actionLabel)),
                  ),
                  if (widget.configure != null &&
                      issue.action != SessionAction.settings)
                    OutlinedButton(
                      onPressed: widget.configure,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: Text(context.tr("编辑连接")),
                    ),
                ],
              ),
              if (session.endReason != SessionEndReason.local &&
                  (session.error.isNotEmpty || session.errorCode != 0)) ...[
                const SizedBox(height: 16),
                ExpansionTile(
                  key: const Key('connectionDiagnostics'),
                  title: Text(
                    context.tr("技术详情"),
                    style: TextStyle(color: Color(0xFFACBEB3), fontSize: 13),
                  ),
                  iconColor: const Color(0xFFACBEB3),
                  collapsedIconColor: const Color(0xFFACBEB3),
                  children: [
                    SelectableText(
                      context.tr("{0}\n代码：0x{1}\n{2}", [
                        session.profile.address,
                        session.errorCode.toRadixString(16).padLeft(8, '0'),
                        session.error.length > 4096
                            ? session.error.substring(0, 4096)
                            : session.error,
                      ]),
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
