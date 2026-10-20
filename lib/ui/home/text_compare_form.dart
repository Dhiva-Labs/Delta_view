import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// Two text boxes to paste snippets into. Compare opens them in the text
/// diff view, where they stay editable.
class TextCompareForm extends StatelessWidget {
  const TextCompareForm({
    super.key,
    required this.left,
    required this.right,
    this.stacked = false,
  });

  final TextEditingController left;
  final TextEditingController right;

  /// One above the other, for narrow windows.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final panes = [
      _TextPane(label: 'Left text', controller: left),
      _TextPane(label: 'Right text', controller: right),
    ];
    if (stacked) {
      return Column(children: [
        panes[0],
        const SizedBox(height: 12),
        panes[1],
      ]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: panes[0]),
        const SizedBox(width: 16),
        Expanded(child: panes[1]),
      ],
    );
  }
}

class _TextPane extends StatefulWidget {
  const _TextPane({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  State<_TextPane> createState() => _TextPaneState();
}

class _TextPaneState extends State<_TextPane> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    widget.controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = widget.controller.text.isNotEmpty;
    final lines = hasText ? '\n'.allMatches(widget.controller.text).length + 1 : 0;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          width: 1.5,
          color: _focus.hasFocus
              ? scheme.primary.withValues(alpha: 0.6)
              : hasText
                  ? scheme.primary.withValues(alpha: 0.4)
                  : scheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 0),
            child: Row(
              children: [
                Icon(Icons.notes,
                    size: 20,
                    color: hasText ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  widget.label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: hasText ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                if (hasText) ...[
                  const SizedBox(width: 8),
                  Text('$lines ${lines == 1 ? 'line' : 'lines'}',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
                const Spacer(),
                TextButton.icon(
                  onPressed: _paste,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: const Text('Paste'),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: hasText ? 1 : 0,
                  child: IconButton(
                    tooltip: 'Clear',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: hasText ? widget.controller.clear : null,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: editorTextStyle(context),
              decoration: InputDecoration(
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                hintText: 'Paste or type here…',
                hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
