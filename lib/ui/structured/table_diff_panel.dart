/// The CSV / TSV diff: one table of rows matched by a key column, with
/// added and removed rows and changed cells highlighted.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../diff/structured/table_diff.dart';
import '../../theme.dart';
import '../shortcuts/app_shortcuts.dart';

const _rowExtent = 28.0;
const _statusWidth = 30.0;
const _numberWidth = 84.0;

class TableDiffPanel extends StatefulWidget {
  const TableDiffPanel({
    super.key,
    required this.diff,
    required this.options,
    required this.onOptionsChanged,
  });

  final TableDiff diff;
  final TableDiffOptions options;
  final ValueChanged<TableDiffOptions> onOptionsChanged;

  @override
  State<TableDiffPanel> createState() => _TableDiffPanelState();
}

class _TableDiffPanelState extends State<TableDiffPanel> {
  bool _changesOnly = true;
  int? _selected;
  late List<RowDiff> _rows;
  late List<double> _widths;
  final _scroll = ScrollController();
  final _hScroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'table diff');

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(TableDiffPanel old) {
    super.didUpdateWidget(old);
    if (old.diff != widget.diff) _prepare();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _hScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _prepare() {
    _selected = null;
    _rows = _changesOnly
        ? widget.diff.rows.where((r) => r.status != RowStatus.same).toList()
        : widget.diff.rows;
    _widths = _columnWidths(widget.diff);
  }

  /// Wide enough for the header and the first few hundred rows (changed
  /// cells hold both values), within sensible bounds.
  static List<double> _columnWidths(TableDiff diff) {
    final chars = [for (final c in diff.columns) c.length + 3];
    final sample = diff.rows.take(400);
    for (final row in sample) {
      for (var c = 0; c < chars.length; c++) {
        final l = row.left[c]?.length ?? 0, r = row.right[c]?.length ?? 0;
        final n = row.changedColumns.contains(c) ? l + r + 5 : math.max(l, r);
        if (n > chars[c]) chars[c] = n;
      }
    }
    return [for (final n in chars) (n * 7.8 + 24).clamp(72.0, 360.0)];
  }

  List<int> get _targets => [
        for (var i = 0; i < _rows.length; i++)
          if (_rows[i].status != RowStatus.same) i,
      ];

  void _go(int direction) {
    final targets = _targets;
    if (targets.isEmpty) return;
    final current = _selected;
    int next;
    if (current == null) {
      next = direction > 0 ? targets.first : targets.last;
    } else {
      next = direction > 0
          ? targets.firstWhere((t) => t > current, orElse: () => current)
          : targets.lastWhere((t) => t < current, orElse: () => current);
    }
    setState(() => _selected = next);
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final top = next * _rowExtent;
    if (top < position.pixels ||
        top + _rowExtent > position.pixels + position.viewportDimension) {
      _scroll.animateTo(
        (top - position.viewportDimension / 3)
            .clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = widget.diff;
    final total =
        _statusWidth + _numberWidth + _widths.fold(0.0, (a, b) => a + b);

    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.nextChange: () => _go(1),
        AppAction.previousChange: () => _go(-1),
      }),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Column(
          children: [
            _toolbar(context),
            const Divider(),
            Expanded(
              child: diff.columns.isEmpty
                  ? Center(
                      child: Text('Both tables are empty.',
                          style: Theme.of(context).textTheme.titleMedium))
                  : LayoutBuilder(builder: (context, constraints) {
                      final width = math.max(total, constraints.maxWidth);
                      // Spare room goes to the last column.
                      final widths = [..._widths];
                      widths[widths.length - 1] += width - total;
                      return Scrollbar(
                        controller: _hScroll,
                        child: SingleChildScrollView(
                          controller: _hScroll,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: width,
                            child: Column(
                              children: [
                                _HeaderRow(diff: diff, widths: widths),
                                Divider(color: scheme.outlineVariant),
                                Expanded(child: _body(context, widths)),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<double> widths) {
    final scheme = Theme.of(context).colorScheme;
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          widget.diff.rows.isEmpty
              ? 'No rows.'
              : 'Every row matches. Turn off "Changes only" to see them.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Listener(
      onPointerDown: (_) => _focus.requestFocus(),
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _rowExtent,
        itemCount: _rows.length,
        itemBuilder: (context, index) => _TableRow(
          row: _rows[index],
          widths: widths,
          keyColumn: widget.diff.keyColumn,
          selected: index == _selected,
          onTap: () => setState(() => _selected = index),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final diff = widget.diff;
    final options = widget.options;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final targets = _targets;
    final position = _selected == null ? -1 : targets.indexOf(_selected!);
    final cells = diff.changedCells;
    final columnsAdded =
        diff.columnStatus.where((s) => s == ColumnStatus.added).length;
    final columnsRemoved =
        diff.columnStatus.where((s) => s == ColumnStatus.removed).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          // On a narrow window the options scroll rather than overflow.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('Header row'),
                    tooltip: 'The first row names the columns',
                    selected: options.header,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) =>
                        widget.onOptionsChanged(options.copyWith(header: v)),
                  ),
                  const SizedBox(width: 8),
                  Text('Match rows by', style: small),
                  const SizedBox(width: 6),
                  PopupMenuButton<int>(
                    tooltip: 'The column that identifies a row',
                    onSelected: (c) =>
                        widget.onOptionsChanged(options.copyWith(keyColumn: c)),
                    itemBuilder: (context) => [
                      for (var c = 0; c < diff.columns.length; c++)
                        CheckedPopupMenuItem(
                          value: c,
                          checked: c == diff.keyColumn,
                          child: Text(diff.columns[c]),
                        ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.key, size: 14, color: scheme.primary),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: Text(
                              diff.columns.isEmpty
                                  ? '—'
                                  : diff.columns[diff.keyColumn],
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Changes only'),
                    selected: _changesOnly,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setState(() {
                      _changesOnly = v;
                      _prepare();
                    }),
                  ),
                  const SizedBox(width: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text(
                      [
                        if (cells > 0)
                          '$cells ${cells == 1 ? 'cell' : 'cells'} changed',
                        if (columnsAdded > 0) '+$columnsAdded columns',
                        if (columnsRemoved > 0) '−$columnsRemoved columns',
                        _rowsTheSame(diff.count(RowStatus.same)),
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small.copyWith(
                          color: cells > 0
                              ? palette.modified
                              : scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (targets.isNotEmpty) ...[
            Text(
              position < 0
                  ? '${targets.length} changed rows'
                  : '${position + 1} / ${targets.length}',
              style: small,
            ),
            IconButton(
              tooltip: 'Previous change (${AppAction.previousChange.keyLabel})',
              onPressed: position != 0 ? () => _go(-1) : null,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Next change (${AppAction.nextChange.keyLabel})',
              onPressed: position < targets.length - 1 ? () => _go(1) : null,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ],
        ],
      ),
    );
  }
}

String _rowsTheSame(int n) => n == 1 ? '1 row the same' : '$n rows the same';

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.diff, required this.widths});

  final TableDiff diff;
  final List<double> widths;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          const SizedBox(width: _statusWidth),
          SizedBox(
            width: _numberWidth,
            child: Tooltip(
              message: 'Row number in the left → right file',
              child: Text('Row', style: style),
            ),
          ),
          for (var c = 0; c < diff.columns.length; c++)
            Container(
              width: widths[c],
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: switch (diff.columnStatus[c]) {
                ColumnStatus.added => palette.addedBg,
                ColumnStatus.removed => palette.removedBg,
                ColumnStatus.same => Colors.transparent,
              },
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (c == diff.keyColumn) ...[
                    Icon(Icons.key, size: 13, color: scheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      switch (diff.columnStatus[c]) {
                        ColumnStatus.added => '+ ${diff.columns[c]}',
                        ColumnStatus.removed => '− ${diff.columns[c]}',
                        ColumnStatus.same => diff.columns[c],
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(
                        color: switch (diff.columnStatus[c]) {
                          ColumnStatus.added => palette.added,
                          ColumnStatus.removed => palette.removed,
                          ColumnStatus.same => c == diff.keyColumn
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.row,
    required this.widths,
    required this.keyColumn,
    required this.selected,
    required this.onTap,
  });

  final RowDiff row;
  final List<double> widths;
  final int keyColumn;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final (Color bg, Color fg, String glyph) = switch (row.status) {
      RowStatus.added => (palette.addedBg, palette.added, '+'),
      RowStatus.removed => (palette.removedBg, palette.removed, '−'),
      RowStatus.changed => (Colors.transparent, palette.modified, '~'),
      RowStatus.same => (Colors.transparent, scheme.onSurfaceVariant, ''),
    };
    final numberStyle = monoStyle.copyWith(
        fontSize: 11.5, color: scheme.onSurfaceVariant.withValues(alpha: 0.7));
    final background = selected
        ? Color.alphaBlend(scheme.primaryContainer.withValues(alpha: 0.6), bg)
        : bg;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: background,
        child: Row(
          children: [
            SizedBox(
              width: _statusWidth,
              child: Text(glyph,
                  textAlign: TextAlign.center,
                  style: monoStyle.copyWith(
                      fontWeight: FontWeight.w700, color: fg)),
            ),
            SizedBox(
              width: _numberWidth,
              child: Text(
                row.leftRow == row.rightRow
                    ? '${row.leftRow}'
                    : '${row.leftRow ?? '·'} → ${row.rightRow ?? '·'}',
                maxLines: 1,
                style: numberStyle,
              ),
            ),
            for (var c = 0; c < widths.length; c++)
              _cell(context, c, palette, scheme),
          ],
        ),
      ),
    );
  }

  Widget _cell(
      BuildContext context, int c, DiffPalette palette, ColorScheme scheme) {
    final width = widths[c];
    final left = row.left[c], right = row.right[c];
    Widget child;
    Color? bg;
    if (row.changedColumns.contains(c)) {
      bg = palette.modifiedBg;
      child = Text.rich(
        TextSpan(children: [
          TextSpan(
            text: left,
            style: TextStyle(
              color: palette.removed,
              decoration: TextDecoration.lineThrough,
              decorationColor: palette.removed.withValues(alpha: 0.6),
            ),
          ),
          TextSpan(
              text: '  →  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          TextSpan(text: right, style: TextStyle(color: palette.added)),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle.copyWith(fontSize: 12.5),
      );
      child = Tooltip(message: '$left  →  $right', child: child);
    } else {
      final value = row.status == RowStatus.removed ? left : (right ?? left);
      child = Text(
        value ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle.copyWith(
          fontSize: 12.5,
          fontWeight: c == keyColumn ? FontWeight.w600 : null,
          color: value == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
              : switch (row.status) {
                  RowStatus.added => palette.added,
                  RowStatus.removed => palette.removed,
                  _ => scheme.onSurface,
                },
        ),
      );
    }
    return Container(
      width: width,
      height: _rowExtent,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }
}
