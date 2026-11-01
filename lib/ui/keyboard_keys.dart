import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rdp/key_mapping.dart';

/// One remote key (a single scancode or a chord) offered by an on-screen
/// keyboard.
class RemoteKeySpec {
  const RemoteKeySpec(this.label, this.keys, {this.repeat = false});

  /// Source-language label; rendered through `context.tr`.
  final String label;

  /// Set 1 scancodes sent as one chord.
  final List<int> keys;

  /// Repeated while the button stays pressed, like a hardware keyboard.
  ///
  /// Only keys whose remote action is safe to repeat (navigation and editing)
  /// opt in; chords and toggles do not.
  final bool repeat;
}

// Keys shared by the compact phone bar and the desktop key panel.
const escKey = RemoteKeySpec('Esc', [0x01]);
const tabKey = RemoteKeySpec('Tab', [0x0f]);
const backspaceKey = RemoteKeySpec('退格', [0x0e], repeat: true);
const enterKey = RemoteKeySpec('回车', [0x1c]);
const arrowLeftKey = RemoteKeySpec('←', [0x14b], repeat: true);
const arrowUpKey = RemoteKeySpec('↑', [0x148], repeat: true);
const arrowDownKey = RemoteKeySpec('↓', [0x150], repeat: true);
const arrowRightKey = RemoteKeySpec('→', [0x14d], repeat: true);
const homeKey = RemoteKeySpec('Home', [0x147], repeat: true);
const endKey = RemoteKeySpec('End', [0x14f], repeat: true);
const pageUpKey = RemoteKeySpec('PgUp', [0x149], repeat: true);
const pageDownKey = RemoteKeySpec('PgDn', [0x151], repeat: true);
const insertKey = RemoteKeySpec('Insert', [0x152]);
const deleteKey = RemoteKeySpec('Delete', [0x153], repeat: true);
const capsLockKey = RemoteKeySpec('CapsLock', [0x3a]);
const numLockKey = RemoteKeySpec('NumLock', [0x45]);
const scrollLockKey = RemoteKeySpec('ScrollLock', [0x46]);
const printScreenKey = RemoteKeySpec('PrintScreen', [0x137]);
const ctrlCKey = RemoteKeySpec('Ctrl+C', [0x1d, 0x2e]);
const ctrlVKey = RemoteKeySpec('Ctrl+V', [0x1d, 0x2f]);
const ctrlXKey = RemoteKeySpec('Ctrl+X', [0x1d, 0x2d]);
const ctrlAKey = RemoteKeySpec('Ctrl+A', [0x1d, 0x1e]);
const ctrlZKey = RemoteKeySpec('Ctrl+Z', [0x1d, 0x2c]);
const ctrlYKey = RemoteKeySpec('Ctrl+Y', [0x1d, 0x15]);
const ctrlShiftEscKey = RemoteKeySpec('Ctrl+Shift+Esc', [0x1d, 0x2a, 0x01]);
const ctrlAltDelKey = RemoteKeySpec('Ctrl+Alt+Del', [0x1d, 0x38, 0x153]);

/// F1–F12 in scan order.
const functionKeys = <RemoteKeySpec>[
  RemoteKeySpec('F1', [0x3b]),
  RemoteKeySpec('F2', [0x3c]),
  RemoteKeySpec('F3', [0x3d]),
  RemoteKeySpec('F4', [0x3e]),
  RemoteKeySpec('F5', [0x3f]),
  RemoteKeySpec('F6', [0x40]),
  RemoteKeySpec('F7', [0x41]),
  RemoteKeySpec('F8', [0x42]),
  RemoteKeySpec('F9', [0x43]),
  RemoteKeySpec('F10', [0x44]),
  RemoteKeySpec('F11', [0x57]),
  RemoteKeySpec('F12', [0x58]),
];

/// Editing and navigation keys shown as their own group on the desktop panel.
const editingKeys = <RemoteKeySpec>[
  escKey,
  tabKey,
  homeKey,
  endKey,
  pageUpKey,
  pageDownKey,
  insertKey,
  deleteKey,
  backspaceKey,
  enterKey,
];

/// Clipboard and system shortcuts grouped on the desktop panel.
const shortcutKeys = <RemoteKeySpec>[
  ctrlCKey,
  ctrlVKey,
  ctrlXKey,
  ctrlAKey,
  ctrlZKey,
  ctrlYKey,
  ctrlShiftEscKey,
  ctrlAltDelKey,
  printScreenKey,
  capsLockKey,
  numLockKey,
  scrollLockKey,
];

/// Number and punctuation keys, sent as US Set 1 chords.
final List<RemoteKeySpec> symbolKeys = [
  for (final rune in '1234567890-=[]\\;\',./!@#\$%^&*()_+{}|:"<>?`~'.runes)
    RemoteKeySpec(String.fromCharCode(rune), rdpCharacterChord(rune)!),
];

/// Compact single-row order used by the phone key bar.
const compactKeys = <RemoteKeySpec>[
  escKey,
  tabKey,
  arrowLeftKey,
  arrowUpKey,
  arrowDownKey,
  arrowRightKey,
  homeKey,
  endKey,
  pageUpKey,
  pageDownKey,
  insertKey,
  deleteKey,
  backspaceKey,
  enterKey,
  ctrlCKey,
  ctrlVKey,
  ctrlXKey,
  ctrlAKey,
  ctrlZKey,
  ctrlYKey,
  capsLockKey,
  numLockKey,
  scrollLockKey,
  printScreenKey,
  ctrlShiftEscKey,
  ctrlAltDelKey,
  ...functionKeys,
];

/// A held key starts repeating at the platform long-press timeout.
const keyRepeatStart = kLongPressTimeout;

/// Repeat period once auto-repeat has started.
const keyRepeatInterval = Duration(milliseconds: 60);

/// A key button that repeats while held, like a hardware keyboard.
///
/// A tap sends one chord on release, so swiping the key bar to scroll it never
/// types into the remote session. Holding the button for the platform
/// long-press timeout sends the key again and then auto-repeats it until the
/// pointer is released.
class RepeatKeyButton extends StatefulWidget {
  const RepeatKeyButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.onRepeat,
    this.tooltip,
    this.hint,
    this.style,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onPressed;

  /// Called for every auto-repeat step. Return false to stop repeating, for
  /// example once the session is no longer connected.
  final bool Function()? onRepeat;
  final String? tooltip;

  /// Accessibility hint, such as "长按连续触发".
  final String? hint;
  final ButtonStyle? style;
  final bool enabled;

  @override
  State<RepeatKeyButton> createState() => _RepeatKeyButtonState();
}

class _RepeatKeyButtonState extends State<RepeatKeyButton> {
  Timer? _repeat;

  bool get _repeatable => widget.enabled && widget.onRepeat != null;

  void _startRepeating() {
    // A short haptic tick confirms that the key started auto-repeating.
    HapticFeedback.selectionClick();
    widget.onPressed();
    _repeat?.cancel();
    _repeat = Timer.periodic(keyRepeatInterval, (timer) {
      if (!(widget.onRepeat?.call() ?? false)) {
        timer.cancel();
        _repeat = null;
      }
    });
  }

  void _stopRepeating() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _stopRepeating();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      onPressed: widget.enabled ? widget.onPressed : null,
      style: widget.style,
      child: widget.child,
    );
    Widget result = button;
    if (_repeatable) {
      result = GestureDetector(
        onLongPressStart: (_) => _startRepeating(),
        onLongPressEnd: (_) => _stopRepeating(),
        onLongPressCancel: _stopRepeating,
        child: button,
      );
    }
    if (widget.tooltip case final tooltip?) {
      result = Tooltip(message: tooltip, child: result);
    }
    if (widget.hint case final hint?) {
      result = Semantics(hint: hint, child: result);
    }
    return result;
  }
}
