/// The strip under the panes: each side's encoding, line endings, line
/// count and caret position, the change being looked at, and the compare
/// rules in force. Encoding and line endings can be changed for the next
/// save from here.
library;

import 'package:flutter/material.dart';

import 'diff_session.dart';

/// What the status bar shows for one side.
class SideStatus {
  const SideStatus({
    required this.format,
    required this.originalFormat,
    required this.lines,
    required this.canChangeFormat,
    this.cursor,
  });

  final TextFormat format;

  /// The format the text was read in (offered first, and the only way to
  /// get mixed line endings back).
  final TextFormat originalFormat;
  final int lines;
  final bool canChangeFormat;

  /// 1-based (line, column) of the caret in edit mode.
  final (int, int)? cursor;
}

class DiffStatusBar extends StatelessWidget {
  const DiffStatusBar({
    super.key,
    required this.left,
    required this.right,
    required this.changeText,
    required this.rules,
    required this.onFormat,
  });

  final SideStatus left;
  final SideStatus right;

  /// e.g. "Change 3 of 12"; rebuilt as the panes scroll.
  final Widget changeText;

  /// Summary of the active compare rules.
  final String rules;

  /// The user picked [format] for [side]'s next save.
  final void Function(int side, TextFormat format) onFormat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant);
    return DefaultTextStyle.merge(
      style: textStyle,
      child: Container(
        height: 26,
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Expanded(child: _side(context, 0, left, Alignment.centerLeft)),
          changeText,
          _dot(),
          Flexible(
            child: Tooltip(
              message: 'Compare rules for this view',
              child: Text(rules, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          Expanded(child: _side(context, 1, right, Alignment.centerRight)),
        ]),
      ),
    );
  }

  Widget _dot() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('·'),
      );

  Widget _side(
      BuildContext context, int side, SideStatus s, Alignment alignment) {
    final changed = s.format != s.originalFormat;
    final items = <Widget>[
      _FormatMenu<TextFormat>(
        label: s.format.encodingLabel,
        tooltip: 'Encoding for the next save',
        changed: !s.format.sameEncoding(s.originalFormat),
        enabled: s.canChangeFormat,
        choices: [
          for (final f in TextFormat.choices)
            (
              f.copyWith(lineEnding: s.format.lineEnding),
              f.encodingLabel,
              f.sameEncoding(s.originalFormat) ? 'as read' : null,
            ),
        ],
        selected: (f) => f.sameEncoding(s.format),
        onSelected: (f) => onFormat(side, f),
      ),
      _FormatMenu<LineEnding>(
        label: s.format.lineEnding.label,
        tooltip: 'Line endings for the next save',
        changed: s.format.lineEnding != s.originalFormat.lineEnding,
        enabled: s.canChangeFormat,
        choices: [
          for (final e in LineEnding.values)
            if (e != LineEnding.mixed ||
                s.originalFormat.lineEnding == LineEnding.mixed)
              (
                e,
                '${e.label} (${e.description})',
                e == s.originalFormat.lineEnding ? 'as read' : null,
              ),
        ],
        selected: (e) => e == s.format.lineEnding,
        onSelected: (e) => onFormat(side, s.format.copyWith(lineEnding: e)),
      ),
      Text('${s.lines} line${s.lines == 1 ? '' : 's'}'),
      if (s.cursor != null) ...[
        _dot(),
        Text('Ln ${s.cursor!.$1}, Col ${s.cursor!.$2}'),
      ],
      if (changed)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: 'The next save changes the encoding or line endings',
            child: Icon(Icons.info_outline,
                size: 13, color: Theme.of(context).colorScheme.primary),
          ),
        ),
    ];
    return Align(
      alignment: alignment,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: alignment == Alignment.centerRight,
        child: Row(mainAxisSize: MainAxisSize.min, children: items),
      ),
    );
  }
}

class _FormatMenu<T> extends StatelessWidget {
  const _FormatMenu({
    required this.label,
    required this.tooltip,
    required this.changed,
    required this.enabled,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final String tooltip;
  final bool changed;
  final bool enabled;

  /// (value, label, note).
  final List<(T, String, String?)> choices;
  final bool Function(T value) selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      position: PopupMenuPosition.over,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final (value, text, note) in choices)
          CheckedPopupMenuItem<T>(
            value: value,
            checked: selected(value),
            child: Row(children: [
              Text(text),
              if (note != null) ...[
                const SizedBox(width: 10),
                Text(note,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: changed ? FontWeight.w700 : null,
            color: changed ? scheme.primary : null,
          ),
        ),
      ),
    );
  }
}
