/// The search bar that floats over both panes (Ctrl+F).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shortcuts/app_shortcuts.dart';
import 'diff_session.dart';

class FindBar extends StatefulWidget {
  const FindBar({
    super.key,
    required this.session,
    required this.focusNode,
    required this.onQueryChanged,
    required this.onStep,
    required this.onClose,
  });

  final DiffSession session;
  final FocusNode focusNode;
  final ValueChanged<String> onQueryChanged;

  /// Go to the next (1) or previous (-1) hit.
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  late final _controller = TextEditingController(text: widget.session.query)
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.session.query.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final scheme = Theme.of(context).colorScheme;
    final count = session.matches.length;
    final status = session.query.isEmpty
        ? ''
        : count == 0
            ? 'No results'
            : '${session.currentMatch + 1} of '
                '$count${count >= maxFindMatches ? '+' : ''}';

    return Material(
      elevation: 6,
      shadowColor: Colors.black38,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 17, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            SizedBox(
              width: 220,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape):
                      widget.onClose,
                  const SingleActivator(LogicalKeyboardKey.enter): () =>
                      widget.onStep(1),
                  const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      () => widget.onStep(-1),
                },
                child: TextField(
                  controller: _controller,
                  focusNode: widget.focusNode,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Find in both files',
                  ),
                  onChanged: widget.onQueryChanged,
                ),
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(status,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 12,
                      color: count == 0 && session.query.isNotEmpty
                          ? scheme.error
                          : scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Match case',
              isSelected: session.matchCase,
              visualDensity: VisualDensity.compact,
              onPressed: () => session.setMatchCase(!session.matchCase),
              icon: const Icon(Icons.text_fields, size: 18),
              selectedIcon:
                  Icon(Icons.text_fields, size: 18, color: scheme.primary),
              style: IconButton.styleFrom(
                backgroundColor: session.matchCase
                    ? scheme.primaryContainer.withValues(alpha: 0.6)
                    : null,
              ),
            ),
            IconButton(
              tooltip: 'Previous match (${AppAction.findPrevious.keyLabel})',
              visualDensity: VisualDensity.compact,
              onPressed: count == 0 ? null : () => widget.onStep(-1),
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: 'Next match (${AppAction.findNext.keyLabel})',
              visualDensity: VisualDensity.compact,
              onPressed: count == 0 ? null : () => widget.onStep(1),
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
            IconButton(
              tooltip: 'Close (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
