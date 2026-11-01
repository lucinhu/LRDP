import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../models/remote_input_mode.dart';
import '../rdp/key_mapping.dart';
import '../rdp/rdp_session.dart';
import 'keyboard_keys.dart';

/// How an on-screen keyboard presents its keys.
enum RemoteKeyboardLayout {
  /// Compact key bar that docks under the phone IME.
  phone,

  /// Grouped key panel docked over a desktop window. The physical keyboard is
  /// still available there, so the panel focuses on sending text and the keys
  /// a desktop keyboard cannot always deliver (for example Ctrl+Alt+Del).
  desktop,
}

/// Editable remote keyboard shared by the phone IME dock and the desktop panel.
class RemoteKeyboard extends StatefulWidget {
  const RemoteKeyboard({
    super.key,
    required this.session,
    required this.close,
    required this.shortcuts,
    this.layout = RemoteKeyboardLayout.phone,
    this.autofocus = true,
    this.allowKeySimulation = true,
    this.simulateKeys = false,
    this.onModeChanged,
    this.pasteText = false,
    this.onPasteTextChanged,
    this.onInputModeChanged,
    this.initialDraft = TextEditingValue.empty,
    this.onDraftChanged,
    this.onSessionShortcut,
    this.initialModifierLock = false,
    this.onModifierLockChanged,
    this.initialNumberKeys = false,
    this.onNumberKeysChanged,
  });
  final RdpSession session;
  final VoidCallback close;
  final bool shortcuts;
  final RemoteKeyboardLayout layout;

  /// Whether opening the panel takes focus. The desktop panel keeps the text
  /// composer ready, while callers that expect the physical keyboard to keep
  /// reaching the remote desktop can opt out.
  final bool autofocus;

  /// Whether the composer offers 键盘模拟. Desktop uses native text delivery
  /// instead: the physical keyboard already sends keystrokes.
  final bool allowKeySimulation;
  final bool simulateKeys;
  final ValueChanged<bool>? onModeChanged;
  final bool pasteText;
  final ValueChanged<bool>? onPasteTextChanged;
  final ValueChanged<RemoteInputMode>? onInputModeChanged;
  final TextEditingValue initialDraft;
  final ValueChanged<TextEditingValue>? onDraftChanged;
  final KeyEventResult Function(KeyEvent)? onSessionShortcut;
  final bool initialModifierLock;
  final ValueChanged<bool>? onModifierLockChanged;
  final bool initialNumberKeys;
  final ValueChanged<bool>? onNumberKeysChanged;
  @override
  State<RemoteKeyboard> createState() => _RemoteKeyboardState();
}

class _RemoteKeyboardState extends State<RemoteKeyboard>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _modeFocus = FocusNode();
  final _textModeFocus = FocusNode();
  final _specialScroll = ScrollController(keepScrollOffset: false);
  final _heldModifiers = <int>{};
  late bool _extraKeys;
  bool _sending = false;
  String? _error;
  static const _anchor = '\u200b';
  late bool _simulateKeys;
  late bool _pasteText;
  late bool _modifierLock;
  late bool _numberKeys;
  bool _updating = false;
  String _keyText = '';
  TextEditingValue _draft = TextEditingValue.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_focusChanged);
    _extraKeys = widget.shortcuts;
    _simulateKeys = widget.allowKeySimulation && widget.simulateKeys;
    _pasteText = widget.pasteText;
    _modifierLock = widget.initialModifierLock;
    _numberKeys = widget.initialNumberKeys;
    _draft = widget.initialDraft.copyWith(composing: TextRange.empty);
    if (_simulateKeys) {
      _resetKeys();
    } else {
      _text.value = _draft;
    }
    _text.addListener(_keysChanged);
    // Autofocus only fills an empty focus scope. The remote surface usually
    // already owns focus after a touch, so opening the composer must take it.
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant RemoteKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _releaseModifiers(session: oldWidget.session);
    }
    if (oldWidget.shortcuts != widget.shortcuts) _extraKeys = widget.shortcuts;
  }

  bool _releaseModifiers({RdpSession? session}) {
    if (_heldModifiers.isEmpty) return false;
    for (final code in _heldModifiers.toList().reversed) {
      (session ?? widget.session).scan(code, false);
    }
    _heldModifiers.clear();
    return true;
  }

  void _focusChanged() {
    if (!_focus.hasFocus && _releaseModifiers() && mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _releaseModifiers()) {
      setState(() {});
    }
  }

  void _toggleModifier(int code) {
    if (_sending || widget.session.state != SessionState.connected) return;
    _editor?.hideToolbar();
    setState(() {
      final down = _heldModifiers.add(code);
      if (!down) _heldModifiers.remove(code);
      widget.session.scan(code, down);
    });
    if (_simulateKeys) _resetKeys();
    _focus.requestFocus();
  }

  void _chord(List<int> keys) {
    // A transient Shift for uppercase text or Ctrl for a shortcut must not
    // release a modifier that the user explicitly latched on the toolbar.
    widget.session.chord(
      keys.where((code) => !_heldModifiers.contains(code)).toList(),
    );
    if (!_modifierLock && _releaseModifiers()) setState(() {});
  }

  void _toggleModifierLock() {
    setState(() {
      _modifierLock = !_modifierLock;
      if (!_modifierLock) _releaseModifiers();
    });
    widget.onModifierLockChanged?.call(_modifierLock);
    _focus.requestFocus();
  }

  void _shortcut(List<int> keys) {
    _editor?.hideToolbar();
    _chord(keys);
    if (_simulateKeys) _resetKeys();
    if (_error != null) setState(() => _error = null);
    _focus.requestFocus();
  }

  /// Repeats a held key. Returns false once repeating is no longer safe.
  bool _repeatKey(List<int> keys) {
    if (!mounted ||
        _sending ||
        widget.session.state != SessionState.connected) {
      return false;
    }
    _chord(keys);
    return true;
  }

  void _toggleNumberKeys() {
    _editor?.hideToolbar();
    setState(() => _numberKeys = !_numberKeys);
    widget.onNumberKeysChanged?.call(_numberKeys);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.removeListener(_focusChanged);
    _releaseModifiers();
    _text.removeListener(_keysChanged);
    _focus.dispose();
    _modeFocus.dispose();
    _textModeFocus.dispose();
    _specialScroll.dispose();
    _text.dispose();
    super.dispose();
  }

  void _resetKeys([String text = '']) {
    _keyText = text;
    _updating = true;
    _text.value = TextEditingValue(
      text: _anchor + text,
      selection: TextSelection.collapsed(offset: text.length + 1),
    );
    _updating = false;
  }

  void _keyAction(int code) => _shortcut([code]);

  EditableTextState? get _editor =>
      _focus.context?.findAncestorStateOfType<EditableTextState>();

  void _showKeyboard() {
    // Rotation or system Back can close the platform connection. Let the
    // editor attach its client before asking Android to show the keyboard.
    final editor = _editor;
    if (editor != null) {
      editor.requestKeyboard();
    } else {
      _focus.requestFocus();
    }
  }

  void _mode(bool keys, {bool paste = false}) {
    if (_sending) return;
    if (keys == _simulateKeys && (keys || paste == _pasteText)) {
      _showKeyboard();
      return;
    }
    _releaseModifiers();
    final wasKeys = _simulateKeys;
    if (keys && !wasKeys) _draft = _text.value;
    setState(() {
      _error = null;
      _simulateKeys = keys;
      _pasteText = paste;
      if (keys) {
        _resetKeys();
      } else if (wasKeys) {
        _text.value = _draft;
      }
    });
    widget.onModeChanged?.call(keys);
    widget.onPasteTextChanged?.call(paste);
    widget.onInputModeChanged?.call(
      keys
          ? RemoteInputMode.keyboard
          : paste
          ? RemoteInputMode.paste
          : RemoteInputMode.text,
    );
    _focus.requestFocus();
  }

  void _keysChanged() {
    if (_updating) return;
    if (!_simulateKeys) {
      _draft = _text.value;
      widget.onDraftChanged?.call(_draft);
      return;
    }
    final value = _text.value;
    final next = value.text.startsWith(_anchor)
        ? value.text.substring(1)
        : value.text;
    if (next == _keyText) {
      // An invisible leading character lets Android report Backspace even
      // when no local text remains. It is never transmitted to the server.
      if (value.text.isEmpty) {
        _chord([0x0e]);
        _resetKeys();
      }
      return;
    }
    var prefix = 0;
    while (prefix < next.length &&
        prefix < _keyText.length &&
        next.codeUnitAt(prefix) == _keyText.codeUnitAt(prefix)) {
      prefix++;
    }
    final added = next.substring(prefix);
    final chords = added.runes.map(rdpCharacterChord).toList();
    if (chords.any((chord) => chord == null) ||
        chords.length + _keyText.length - prefix > 64) {
      setState(() {
        _error = chords.any((chord) => chord == null)
            ? '此内容无法模拟为按键，请切换“文字输入”或“粘贴输入”。'
            : '请逐字输入；长段文字请切换“文字输入”。';
      });
      _resetKeys(_keyText);
      return;
    }
    if (_error != null) setState(() => _error = null);
    for (var i = prefix; i < _keyText.length; i++) {
      _chord([0x0e]);
    }
    for (final chord in chords) {
      _chord(chord!);
    }
    _keyText = next;
    if (next.isEmpty ||
        (!(value.composing.isValid && !value.composing.isCollapsed) &&
            (next.length > 64 || added.contains('\n')))) {
      _resetKeys();
    }
  }

  Future<void> _send() async {
    final value = _text.value;
    // Some IMEs keep a composing range after choosing Chinese candidates.
    // Explicit Send commits the displayed text; edits alone never send it.
    if (_sending ||
        value.text.isEmpty ||
        value.text.codeUnits.length > 16384 ||
        widget.session.state != SessionState.connected) {
      return;
    }
    _releaseModifiers();
    _text.clearComposing();
    setState(() => _error = null);
    if (!_pasteText) {
      if (!widget.session.unicodeInputSupported) {
        setState(() => _error = '远端不支持直接文字输入，请切换“粘贴输入”后发送。');
        return;
      }
      widget.session.text(value.text);
      _text.clear();
      return;
    }
    setState(() => _sending = true);
    final ok = await widget.session.paste(value.text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        // A successful operation confirms the remote clipboard transfer. Keep
        // text entered while it was in flight rather than clearing newer work.
        if (_text.text == value.text) _text.clear();
      } else {
        _error = widget.session.pasteError;
      }
    });
  }

  // Android IMEs can deliver editing keys as hardware events instead of text
  // edits. Handle them before EditableText moves its invisible local caret.
  KeyEventResult _editingKey(FocusNode node, KeyEvent event) {
    final shortcut = widget.onSessionShortcut?.call(event);
    if (shortcut == KeyEventResult.handled) return KeyEventResult.handled;
    if (!_simulateKeys ||
        !_focus.hasFocus ||
        widget.session.state != SessionState.connected) {
      return KeyEventResult.ignored;
    }
    // The hidden editor has no traversal position. Give keyboard users a
    // predictable local escape to the mode menu; remote Tab is on the key bar.
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (event is KeyDownEvent) _modeFocus.requestFocus();
      return KeyEventResult.handled;
    }
    final code = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.enter: 0x1c,
      LogicalKeyboardKey.numpadEnter: 0x11c,
      LogicalKeyboardKey.backspace: 0x0e,
      LogicalKeyboardKey.delete: 0x153,
      LogicalKeyboardKey.arrowLeft: 0x14b,
      LogicalKeyboardKey.arrowRight: 0x14d,
      LogicalKeyboardKey.arrowUp: 0x148,
      LogicalKeyboardKey.arrowDown: 0x150,
      LogicalKeyboardKey.home: 0x147,
      LogicalKeyboardKey.end: 0x14f,
      LogicalKeyboardKey.pageUp: 0x149,
      LogicalKeyboardKey.pageDown: 0x151,
      LogicalKeyboardKey.escape: 0x01,
    }[event.logicalKey];
    if (code == null) return KeyEventResult.ignored;
    final modifiers = HardwareKeyboard.instance;
    if (event is! KeyUpEvent) {
      _shortcut([
        if (modifiers.isControlPressed) 0x1d,
        if (modifiers.isShiftPressed) 0x2a,
        if (modifiers.isAltPressed) 0x38,
        if (modifiers.isMetaPressed) 0x15b,
        code,
      ]);
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- widgets

  String get _modeLabel => _simulateKeys
      ? '键盘模拟'
      : _pasteText
      ? '粘贴输入'
      : '文字输入';

  String get _modeTooltip => _simulateKeys
      ? '输入模式：键盘模拟'
      : _pasteText
      ? '输入模式：粘贴输入'
      : '输入模式：文字输入';

  IconData get _modeIcon => _simulateKeys
      ? Icons.keyboard
      : _pasteText
      ? Icons.content_paste
      : Icons.translate;

  void _openModeMenu(MenuController controller) {
    if (_sending) return;
    if (controller.isOpen) {
      controller.close();
      return;
    }
    // MenuAnchor avoids the IME. Keep touch input focused; physical-keyboard
    // activation enters the menu instead.
    final keyboardNavigation = !_focus.hasFocus;
    // Selection handles use their own overlay. Hide them before the menu so
    // they cannot intercept a mode choice on a short, large-text screen.
    _editor?.hideToolbar();
    controller.open();
    if (keyboardNavigation) _textModeFocus.requestFocus();
  }

  Widget _modeMenu(BuildContext context, {required bool desktop}) {
    return MenuAnchor(
      consumeOutsideTap: true,
      menuChildren: [
        MenuItemButton(
          focusNode: _textModeFocus,
          onPressed: () => _mode(false),
          child: Text(context.tr("文字输入")),
        ),
        MenuItemButton(
          onPressed: () => _mode(false, paste: true),
          child: Text(context.tr("粘贴输入")),
        ),
        if (widget.allowKeySimulation)
          MenuItemButton(
            onPressed: () => _mode(true),
            child: Text(context.tr("键盘模拟")),
          ),
      ],
      builder: (context, controller, _) => desktop
          ? OutlinedButton.icon(
              key: const Key('remoteInputMode'),
              focusNode: _modeFocus,
              onPressed: _sending ? null : () => _openModeMenu(controller),
              icon: Icon(_modeIcon, size: 18),
              label: Text(context.tr(_modeLabel)),
            )
          : IconButton(
              key: const Key('remoteInputMode'),
              focusNode: _modeFocus,
              tooltip: context.tr(_modeTooltip),
              onPressed: _sending ? null : () => _openModeMenu(controller),
              icon: Icon(_modeIcon),
            ),
    );
  }

  Widget _editorArea(BuildContext context, {required bool desktop}) => Stack(
    alignment: Alignment.center,
    children: [
      Offstage(
        offstage: _simulateKeys,
        // Keep the real InputConnection alive without painting a local input
        // box in keyboard simulation mode.
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _editingKey,
          child: TextField(
            key: const Key('remoteTextInput'),
            controller: _text,
            focusNode: _focus,
            autofocus: widget.autofocus,
            showCursor: !_simulateKeys,
            minLines: desktop ? 3 : 1,
            maxLines: _simulateKeys ? null : (desktop ? 5 : 2),
            keyboardType: _simulateKeys
                ? TextInputType.visiblePassword
                : TextInputType.multiline,
            textInputAction: _simulateKeys
                ? TextInputAction.done
                : TextInputAction.newline,
            onSubmitted: _simulateKeys ? (_) => _keyAction(0x1c) : null,
            onEditingComplete: _simulateKeys ? () {} : null,
            autocorrect: !_simulateKeys,
            enableSuggestions: !_simulateKeys,
            enableInteractiveSelection: !_simulateKeys,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            decoration: InputDecoration(
              labelText: _simulateKeys
                  ? context.tr("键盘模拟 · 输入即发送")
                  : _pasteText
                  ? context.tr("粘贴输入")
                  : context.tr("文字输入"),
              hintText: context.tr("输入文字后发送"),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: desktop ? 12 : 10,
              ),
            ),
          ),
        ),
      ),
      if (_simulateKeys)
        TextButton(onPressed: _showKeyboard, child: Text(context.tr("显示键盘"))),
    ],
  );

  Widget _sendButton(
    BuildContext context, {
    required bool desktop,
  }) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _text,
    builder: (context, value, _) {
      final tooLong = value.text.codeUnits.length > 16384;
      final enabled = !_sending && value.text.isNotEmpty && !tooLong;
      final progress = _sending
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null;
      if (desktop) {
        return Tooltip(
          message: tooLong ? context.tr("内容过长，请分段发送") : context.tr("发送文字"),
          child: FilledButton.icon(
            key: const Key('pasteRemoteText'),
            onPressed: enabled ? _send : null,
            icon: progress ?? const Icon(Icons.arrow_upward_rounded, size: 18),
            label: Text(context.tr("发送")),
          ),
        );
      }
      return IconButton.filled(
        key: const Key('pasteRemoteText'),
        tooltip: tooLong ? context.tr("内容过长，请分段发送") : context.tr("发送文字"),
        onPressed: enabled ? _send : null,
        icon: progress ?? const Icon(Icons.arrow_upward_rounded),
      );
    },
  );

  Widget _modifier(String label, int code, {ButtonStyle? style}) {
    final held = _heldModifiers.contains(code);
    return Semantics(
      toggled: held,
      child: TextButton(
        key: Key('remoteModifier$label'),
        onPressed: _sending ? null : () => _toggleModifier(code),
        style:
            style ??
            TextButton.styleFrom(
              minimumSize: const Size(64, 48),
              backgroundColor: held
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              foregroundColor: held
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : null,
            ),
        child: Text(context.tr(label)),
      ),
    );
  }

  Widget _lockButton() => Semantics(
    toggled: _modifierLock,
    child: IconButton.filledTonal(
      key: const Key('remoteModifierLock'),
      tooltip: _modifierLock
          ? context.tr('锁定模式已开启：点击关闭并释放修饰键')
          : context.tr('锁定模式已关闭：修饰键使用一次后释放，点击开启'),
      isSelected: _modifierLock,
      onPressed: _sending ? null : _toggleModifierLock,
      icon: const Icon(Icons.lock_open_outlined),
      selectedIcon: const Icon(Icons.lock_outline),
    ),
  );

  /// Header toggle that only looks filled while its section is visible.
  Widget _headerToggle({
    required Key key,
    required String tooltip,
    required bool active,
    required IconData icon,
    required IconData selectedIcon,
    required VoidCallback? onPressed,
  }) => active
      ? IconButton.filledTonal(
          key: key,
          tooltip: tooltip,
          isSelected: true,
          icon: Icon(icon),
          selectedIcon: Icon(selectedIcon),
          onPressed: onPressed,
        )
      : IconButton(
          key: key,
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: onPressed,
        );

  Widget _extraKeysButton() => IconButton(
    key: const Key('remoteExtraKeys'),
    tooltip: _extraKeys ? context.tr("收起特殊按键") : context.tr("展开特殊按键"),
    isSelected: _extraKeys,
    onPressed: () => setState(() => _extraKeys = !_extraKeys),
    icon: Icon(_extraKeys ? Icons.expand_less : Icons.more_horiz),
  );

  Widget _numberKeysButton({required bool desktop}) => IconButton.filledTonal(
    key: const Key('remoteNumberKeys'),
    tooltip: desktop
        ? (_numberKeys ? context.tr('隐藏数字和符号') : context.tr('显示数字和符号'))
        : (_numberKeys ? context.tr('显示导航和功能键') : context.tr('显示数字和符号')),
    isSelected: _numberKeys,
    icon: const Icon(Icons.numbers),
    selectedIcon: const Icon(Icons.keyboard_alt_outlined),
    onPressed: _sending ? null : _toggleNumberKeys,
  );

  Widget _errorText(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Text(
      context.tr(_error!),
      style: TextStyle(
        color: Theme.of(context).colorScheme.error,
        fontSize: 12,
      ),
    ),
  );

  double get _keyHeight =>
      (MediaQuery.textScalerOf(context).scale(14) + 20).clamp(48.0, 80.0);

  List<RemoteKeySpec> get _specialKeys =>
      _numberKeys ? symbolKeys : compactKeys;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: switch (widget.layout) {
      RemoteKeyboardLayout.phone => _phone(context),
      RemoteKeyboardLayout.desktop => _desktop(context),
    },
  );

  // ------------------------------------------------------------- phone layout

  Widget _phone(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _keyHeight,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  key: const Key('remoteModifierKeys'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  children: [
                    _modifier('Ctrl', 0x1d),
                    _modifier('Shift', 0x2a),
                    _modifier('Alt', 0x38),
                    _modifier('Win', 0x15b),
                    TextButton(
                      key: const Key('remoteKeySpace'),
                      onPressed: _sending ? null : () => _keyAction(0x39),
                      child: Text(context.tr("空格")),
                    ),
                  ],
                ),
              ),
              _lockButton(),
              _extraKeysButton(),
            ],
          ),
        ),
        if (_extraKeys)
          SizedBox(
            height: _keyHeight,
            child: Row(
              children: [
                _numberKeysButton(desktop: false),
                Expanded(
                  child: SizedBox(
                    key: const Key('remoteSpecialKeys'),
                    child: ListView(
                      key: ValueKey('remote-number-keys-$_numberKeys'),
                      controller: _specialScroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final spec in _specialKeys)
                          RepeatKeyButton(
                            key: Key('remoteKey${spec.label}'),
                            enabled: !_sending,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(52, 48),
                            ),
                            hint: spec.repeat ? context.tr('长按连续触发') : null,
                            onPressed: () => _shortcut(spec.keys),
                            onRepeat: spec.repeat
                                ? () => _repeatKey(spec.keys)
                                : null,
                            child: Text(context.tr(spec.label)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: context.tr("收起键盘"),
                onPressed: _sending ? null : widget.close,
                icon: const Icon(Icons.keyboard_hide_outlined),
              ),
              _modeMenu(context, desktop: false),
              Expanded(child: _editorArea(context, desktop: false)),
              if (_simulateKeys) ...[
                RepeatKeyButton(
                  key: const Key('remoteBackspace'),
                  enabled: !_sending,
                  tooltip: context.tr("退格"),
                  hint: context.tr('长按连续触发'),
                  style: TextButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(12),
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => _keyAction(0x0e),
                  onRepeat: () => _repeatKey(const [0x0e]),
                  child: const Icon(Icons.backspace_outlined),
                ),
                IconButton(
                  tooltip: context.tr("回车"),
                  onPressed: _sending ? null : () => _keyAction(0x1c),
                  icon: const Icon(Icons.keyboard_return),
                ),
              ],
              if (!_simulateKeys) _sendButton(context, desktop: false),
            ],
          ),
        ),
        if (_error != null) _errorText(context),
      ],
    ),
  );

  // ----------------------------------------------------------- desktop layout

  ButtonStyle _keyStyle(BuildContext context, {bool selected = false}) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton.styleFrom(
      minimumSize: const Size(46, 38),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      foregroundColor: selected ? scheme.onPrimaryContainer : scheme.onSurface,
      backgroundColor: selected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHigh,
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: .45)
            : scheme.outlineVariant.withValues(alpha: .8),
      ),
    );
  }

  Widget _desktop(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('remoteKeyboardPanel'),
      color: scheme.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _desktopHeader(context),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: .6),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 700;
                  final composer = _desktopComposer(context);
                  final keys = _desktopKeyArea(context);
                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        composer,
                        const SizedBox(height: 14),
                        const Divider(height: 1),
                        const SizedBox(height: 14),
                        keys,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 330, child: composer),
                      const SizedBox(width: 24),
                      const VerticalDivider(width: 1),
                      const SizedBox(width: 24),
                      Expanded(child: keys),
                    ],
                  );
                },
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: _errorText(context),
            ),
        ],
      ),
    );
  }

  Widget _desktopHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.keyboard_alt_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Text(
            context.tr("屏幕键盘"),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          _headerToggle(
            key: const Key('remoteNumberKeys'),
            tooltip: _numberKeys
                ? context.tr('隐藏数字和符号')
                : context.tr('显示数字和符号'),
            active: _numberKeys,
            icon: Icons.numbers,
            selectedIcon: Icons.keyboard_alt_outlined,
            onPressed: _sending ? null : _toggleNumberKeys,
          ),
          _headerToggle(
            key: const Key('remoteExtraKeys'),
            tooltip: _extraKeys ? context.tr('收起特殊按键') : context.tr('展开特殊按键'),
            active: _extraKeys,
            icon: Icons.more_horiz,
            selectedIcon: Icons.expand_less,
            onPressed: () => setState(() => _extraKeys = !_extraKeys),
          ),
          IconButton(
            tooltip: context.tr("收起键盘"),
            onPressed: _sending ? null : widget.close,
            icon: const Icon(Icons.keyboard_hide_outlined),
          ),
        ],
      ),
    );
  }

  Widget _desktopComposer(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          _modeMenu(context, desktop: true),
          const Spacer(),
          _sendButton(context, desktop: true),
        ],
      ),
      const SizedBox(height: 10),
      _editorArea(context, desktop: true),
      const SizedBox(height: 8),
      Text(
        context.tr("长按方向键或编辑键可连续触发"),
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _desktopKeyArea(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      _keyGroup(context, context.tr("修饰键"), [
        _modifier(
          'Ctrl',
          0x1d,
          style: _keyStyle(context, selected: _heldModifiers.contains(0x1d)),
        ),
        _modifier(
          'Shift',
          0x2a,
          style: _keyStyle(context, selected: _heldModifiers.contains(0x2a)),
        ),
        _modifier(
          'Alt',
          0x38,
          style: _keyStyle(context, selected: _heldModifiers.contains(0x38)),
        ),
        _modifier(
          'Win',
          0x15b,
          style: _keyStyle(context, selected: _heldModifiers.contains(0x15b)),
        ),
        _lockButton(),
      ]),
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _keyGroup(context, context.tr("方向键"), [_arrowCluster(context)]),
          const SizedBox(width: 20),
          Expanded(
            child: _keyGroup(context, context.tr("编辑键"), [
              for (final spec in editingKeys) _desktopKey(context, spec),
            ]),
          ),
        ],
      ),
      if (_extraKeys) ...[
        const SizedBox(height: 14),
        _keyGroup(context, context.tr("功能键"), [
          for (final spec in functionKeys) _desktopKey(context, spec),
        ]),
      ],
      if (_extraKeys || _numberKeys) ...[
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_extraKeys)
              Expanded(
                child: _keyGroup(context, context.tr("组合键"), [
                  for (final spec in shortcutKeys) _desktopKey(context, spec),
                ]),
              ),
            if (_extraKeys && _numberKeys) const SizedBox(width: 20),
            if (_numberKeys)
              Expanded(
                child: _keyGroup(context, context.tr("数字与符号"), [
                  for (final spec in symbolKeys) _desktopKey(context, spec),
                ]),
              ),
          ],
        ),
      ],
    ],
  );

  Widget _keyGroup(BuildContext context, String title, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: .6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Wrap(spacing: 6, runSpacing: 6, children: children),
      ],
    );
  }

  Widget _arrowCluster(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _desktopKey(context, arrowUpKey),
      const SizedBox(height: 6),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _desktopKey(context, arrowLeftKey),
          const SizedBox(width: 6),
          _desktopKey(context, arrowDownKey),
          const SizedBox(width: 6),
          _desktopKey(context, arrowRightKey),
        ],
      ),
    ],
  );

  Widget _desktopKey(BuildContext context, RemoteKeySpec spec) =>
      RepeatKeyButton(
        key: Key('remoteKey${spec.label}'),
        enabled: !_sending,
        style: _keyStyle(context),
        hint: spec.repeat ? context.tr('长按连续触发') : null,
        onPressed: () => _shortcut(spec.keys),
        onRepeat: spec.repeat ? () => _repeatKey(spec.keys) : null,
        child: Text(context.tr(spec.label), maxLines: 1),
      );
}
