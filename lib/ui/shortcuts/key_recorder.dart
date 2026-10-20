import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_shortcuts.dart';

/// Grabs keyboard focus and reports the first key combination pressed.
/// Esc cancels, and so does losing focus. Key events are swallowed while
/// recording so the app's own shortcuts (Ctrl+W!) do not fire.
class ShortcutRecorder extends StatefulWidget {
  const ShortcutRecorder({
    super.key,
    required this.onRecorded,
    required this.onCancel,
    required this.child,
  });

  final ValueChanged<SingleActivator> onRecorded;
  final VoidCallback onCancel;
  final Widget child;

  @override
  State<ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<ShortcutRecorder> {
  final _focus = FocusNode(debugLabel: 'shortcut recorder');
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus && !_done) {
      _done = true;
      widget.onCancel();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_done) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _done = true;
      widget.onCancel();
      return KeyEventResult.handled;
    }
    final activator = activatorForKeyEvent(event);
    if (activator != null) {
      _done = true;
      widget.onRecorded(activator);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
