import '../l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/remote_input_mode.dart';
import '../rdp/key_mapping.dart';
import '../rdp/rdp_session.dart';

class MobileKeyboard extends StatefulWidget {
  const MobileKeyboard({
    super.key,
    required this.session,
    required this.close,
    required this.shortcuts,
    this.simulateKeys = false,
    this.onModeChanged,
    this.pasteText = false,
    this.onPasteTextChanged,
    this.onInputModeChanged,
    this.initialDraft = TextEditingValue.empty,
    this.onDraftChanged,
    this.onSessionShortcut,
  });
  final RdpSession session;
  final VoidCallback close;
  final bool shortcuts;
  final bool simulateKeys;
  final ValueChanged<bool>? onModeChanged;
  final bool pasteText;
  final ValueChanged<bool>? onPasteTextChanged;
  final ValueChanged<RemoteInputMode>? onInputModeChanged;
  final TextEditingValue initialDraft;
  final ValueChanged<TextEditingValue>? onDraftChanged;
  final KeyEventResult Function(KeyEvent)? onSessionShortcut;
  @override
  State<MobileKeyboard> createState() => _MobileKeyboardState();
}

class _MobileKeyboardState extends State<MobileKeyboard>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _modeFocus = FocusNode();
  final _textModeFocus = FocusNode();
  final _heldModifiers = <int>{};
  late bool _extraKeys;
  bool _sending = false;
  String? _error;
  static const _anchor = '\u200b';
  late bool _simulateKeys;
  late bool _pasteText;
  bool _updating = false;
  String _keyText = '';
  TextEditingValue _draft = TextEditingValue.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_focusChanged);
    _extraKeys = widget.shortcuts;
    _simulateKeys = widget.simulateKeys;
    _pasteText = widget.pasteText;
    _draft = widget.initialDraft.copyWith(composing: TextRange.empty);
    if (_simulateKeys) {
      _resetKeys();
    } else {
      _text.value = _draft;
    }
    _text.addListener(_keysChanged);
    // Autofocus only fills an empty focus scope. The remote surface usually
    // already owns focus after a touch, so opening the composer must take it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant MobileKeyboard oldWidget) {
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
  }

  void _shortcut(List<int> keys) {
    _editor?.hideToolbar();
    _chord(keys);
    if (_simulateKeys) _resetKeys();
    if (_error != null) setState(() => _error = null);
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

  Widget _modifier(String label, int code) {
    final held = _heldModifiers.contains(code);
    return Semantics(
      toggled: held,
      child: TextButton(
        key: Key('remoteModifier$label'),
        onPressed: _sending ? null : () => _toggleModifier(code),
        style: TextButton.styleFrom(
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

  double get _keyHeight =>
      (MediaQuery.textScalerOf(context).scale(14) + 20).clamp(48.0, 80.0);

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: Material(
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
                IconButton(
                  key: const Key('releaseRemoteModifiers'),
                  tooltip: context.tr('释放修饰键'),
                  onPressed: _heldModifiers.isEmpty
                      ? null
                      : () {
                          setState(() => _releaseModifiers());
                          _focus.requestFocus();
                        },
                  icon: const Icon(Icons.lock_open_outlined),
                ),
                IconButton(
                  key: const Key('remoteExtraKeys'),
                  tooltip: _extraKeys
                      ? context.tr("收起特殊按键")
                      : context.tr("展开特殊按键"),
                  onPressed: () => setState(() => _extraKeys = !_extraKeys),
                  icon: Icon(_extraKeys ? Icons.expand_less : Icons.more_horiz),
                ),
              ],
            ),
          ),
          if (_extraKeys)
            SizedBox(
              height: _keyHeight,
              child: ListView(
                key: const Key('remoteSpecialKeys'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final entry in <String, List<int>>{
                    'Esc': [0x01],
                    'Tab': [0x0f],
                    'Ctrl+C': [0x1d, 0x2e],
                    'Ctrl+V': [0x1d, 0x2f],
                    'Ctrl+A': [0x1d, 0x1e],
                    '←': [0x14b],
                    '↑': [0x148],
                    '↓': [0x150],
                    '→': [0x14d],
                    for (var i = 1; i <= 10; i++) 'F$i': [0x3a + i],
                    'F11': [0x57],
                    'F12': [0x58],
                    'Home': [0x147],
                    'End': [0x14f],
                    'PgUp': [0x149],
                    'PgDn': [0x151],
                    'Insert': [0x152],
                    'Delete': [0x153],
                    '退格': [0x0e],
                    '回车': [0x1c],
                    'CapsLock': [0x3a],
                    'NumLock': [0x45],
                    'ScrollLock': [0x46],
                    'PrintScreen': [0x137],
                    'Ctrl+Shift+Esc': [0x1d, 0x2a, 0x01],
                    'Ctrl+Alt+Del': [0x1d, 0x38, 0x153],
                  }.entries)
                    TextButton(
                      key: Key('remoteKey${entry.key}'),
                      onPressed: _sending ? null : () => _shortcut(entry.value),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(52, 48),
                      ),
                      child: Text(context.tr(entry.key)),
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
                MenuAnchor(
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
                    MenuItemButton(
                      onPressed: () => _mode(true),
                      child: Text(context.tr("键盘模拟")),
                    ),
                  ],
                  builder: (context, controller, _) => IconButton(
                    key: const Key('remoteInputMode'),
                    focusNode: _modeFocus,
                    tooltip: _simulateKeys
                        ? context.tr("输入模式：键盘模拟")
                        : _pasteText
                        ? context.tr("输入模式：粘贴输入")
                        : context.tr("输入模式：文字输入"),
                    onPressed: _sending
                        ? null
                        : () {
                            if (controller.isOpen) {
                              controller.close();
                            } else {
                              // MenuAnchor avoids the IME. Keep touch input focused;
                              // physical-keyboard activation enters the menu instead.
                              final keyboardNavigation = !_focus.hasFocus;
                              // Selection handles use their own overlay. Hide
                              // them before the menu so they cannot intercept
                              // a mode choice on a short, large-text screen.
                              _editor?.hideToolbar();
                              controller.open();
                              if (keyboardNavigation) {
                                _textModeFocus.requestFocus();
                              }
                            }
                          },
                    icon: Icon(
                      _simulateKeys ? Icons.keyboard : Icons.translate,
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Offstage(
                        offstage: _simulateKeys,
                        // Keep the real InputConnection alive without painting
                        // a local input box in keyboard simulation mode.
                        child: Focus(
                          canRequestFocus: false,
                          skipTraversal: true,
                          onKeyEvent: _editingKey,
                          child: TextField(
                            key: const Key('remoteTextInput'),
                            controller: _text,
                            focusNode: _focus,
                            autofocus: true,
                            showCursor: !_simulateKeys,
                            minLines: 1,
                            maxLines: _simulateKeys ? null : 2,
                            keyboardType: _simulateKeys
                                ? TextInputType.visiblePassword
                                : TextInputType.multiline,
                            textInputAction: _simulateKeys
                                ? TextInputAction.done
                                : TextInputAction.newline,
                            onSubmitted: _simulateKeys
                                ? (_) => _keyAction(0x1c)
                                : null,
                            onEditingComplete: _simulateKeys ? () {} : null,
                            autocorrect: !_simulateKeys,
                            enableSuggestions: !_simulateKeys,
                            enableInteractiveSelection: !_simulateKeys,
                            smartDashesType: SmartDashesType.disabled,
                            smartQuotesType: SmartQuotesType.disabled,
                            decoration: InputDecoration(
                              labelText: _simulateKeys
                                  ? context.tr("键盘模拟 · 输入即发送")
                                  : context.tr("文字输入"),
                              hintText: context.tr("输入文字后发送"),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_simulateKeys)
                        TextButton(
                          onPressed: _showKeyboard,
                          child: Text(context.tr("显示键盘")),
                        ),
                    ],
                  ),
                ),
                if (_simulateKeys) ...[
                  IconButton(
                    tooltip: context.tr("退格"),
                    onPressed: () => _keyAction(0x0e),
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                  IconButton(
                    tooltip: context.tr("回车"),
                    onPressed: () => _keyAction(0x1c),
                    icon: const Icon(Icons.keyboard_return),
                  ),
                ],
                if (!_simulateKeys)
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _text,
                    builder: (context, value, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.filled(
                          key: const Key('pasteRemoteText'),
                          tooltip: value.text.codeUnits.length > 16384
                              ? context.tr("内容过长，请分段发送")
                              : context.tr("发送文字"),
                          onPressed:
                              !_sending &&
                                  value.text.isNotEmpty &&
                                  value.text.codeUnits.length <= 16384
                              ? _send
                              : null,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_upward_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                context.tr(error),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
