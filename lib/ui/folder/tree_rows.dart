/// The rows of the Meld-style dual-pane folder tree and its sortable
/// column headers.
library;

import 'package:flutter/material.dart';

import '../../compare/folder_compare.dart';
import '../../compare/folder_format.dart';
import '../../compare/folder_report.dart' show statusLabel;
import '../../settings/app_settings.dart';
import '../../theme.dart';
import 'tree_model.dart';

const sizeColWidth = 62.0;
const timeColWidth = 116.0;

/// Width of the status column between the two panes.
const gutterWidth = 30.0;

double rowExtentFor(UiDensity density) =>
    density == UiDensity.compact ? 26 : 34;

String formatTime(DateTime? time, DateStyle style) {
  if (time == null) return '';
  return switch (style) {
    DateStyle.short => formatDateShort(time),
    DateStyle.iso => formatDateIso(time),
    DateStyle.relative => formatDateRelative(time),
  };
}

/// The status of an entry as an icon, so it reads without colour too.
/// The same icons label the counts in the summary above the tree.
IconData statusIcon(EntryStatus status) => switch (status) {
      EntryStatus.identical => Icons.check_circle_outline,
      EntryStatus.modified => Icons.edit_outlined,
      EntryStatus.onlyLeft => Icons.remove_circle_outline,
      EntryStatus.onlyRight => Icons.add_circle_outline,
    };

String statusTooltip(CompareNode node) {
  if (node.isTypeConflict) {
    return node.folderSide == Side.left
        ? 'A folder on the left, a file on the right'
        : 'A file on the left, a folder on the right';
  }
  if (node.isDirectory && node.status == EntryStatus.modified) {
    return 'Contains changes';
  }
  final label = statusLabel(node.status);
  return '${label[0].toUpperCase()}${label.substring(1)}';
}

class FolderColumnHeaders extends StatelessWidget {
  const FolderColumnHeaders({
    super.key,
    required this.sort,
    required this.onSort,
  });

  final TreeSort sort;
  final ValueChanged<TreeSort> onSort;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final divider = scheme.outlineVariant.withValues(alpha: 0.5);

    Widget header(String label, SortColumn column, Side side,
        {TextAlign align = TextAlign.left}) {
      final active = sort.column == column &&
          (column == SortColumn.name || sort.side == side);
      final style = TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: active ? scheme.primary : scheme.onSurfaceVariant,
      );
      final arrow = Icon(
        sort.ascending ? Icons.arrow_upward : Icons.arrow_downward,
        size: 12,
        color: scheme.primary,
      );
      return Semantics(
        button: true,
        label: 'Sort by $label',
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => onSort(TreeSort(
            column,
            side: side,
            ascending: active ? !sort.ascending : true,
          )),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: align == TextAlign.right
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (active && align == TextAlign.right) ...[
                  arrow,
                  const SizedBox(width: 2),
                ],
                Flexible(
                  child: Text(label,
                      maxLines: 1, overflow: TextOverflow.fade, style: style),
                ),
                if (active && align != TextAlign.right) ...[
                  const SizedBox(width: 2),
                  arrow,
                ],
              ],
            ),
          ),
        ),
      );
    }

    Widget pane(Side side) => Expanded(
          child: Row(
            children: [
              const SizedBox(width: 10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: header('Name', SortColumn.name, side),
                ),
              ),
              SizedBox(
                width: sizeColWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: header('Size', SortColumn.size, side,
                      align: TextAlign.right),
                ),
              ),
              SizedBox(
                width: timeColWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: header('Modified', SortColumn.modified, side,
                      align: TextAlign.right),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        );

    return SizedBox(
      height: 28,
      child: Row(children: [
        pane(Side.left),
        VerticalDivider(width: 1, color: divider),
        const SizedBox(width: gutterWidth),
        VerticalDivider(width: 1, color: divider),
        pane(Side.right),
      ]),
    );
  }
}

/// One aligned row of the dual-pane tree: the same entry rendered for the
/// left and right folder, with its status between them. The pane where the
/// entry doesn't exist renders as an empty slot.
class FolderTreeRow extends StatelessWidget {
  const FolderTreeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.palette,
    required this.expanded,
    required this.selected,
    required this.cursor,
    required this.focused,
    required this.dateStyle,
    required this.compact,
    required this.onTapDown,
    required this.onSecondaryTapDown,
  });

  final CompareNode node;
  final int depth;
  final DiffPalette palette;
  final bool expanded;
  final bool selected;

  /// The keyboard cursor is on this row.
  final bool cursor;

  /// The tree has keyboard focus (the cursor outline only shows then).
  final bool focused;
  final DateStyle dateStyle;
  final bool compact;
  final GestureTapDownCallback onTapDown;
  final GestureTapDownCallback onSecondaryTapDown;

  Color _statusColor(ColorScheme scheme) => switch (node.status) {
        EntryStatus.identical => scheme.onSurfaceVariant,
        EntryStatus.modified => palette.modified,
        EntryStatus.onlyLeft => palette.removed,
        EntryStatus.onlyRight => palette.added,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final divider = scheme.outlineVariant.withValues(alpha: 0.5);
    final background = selected
        ? scheme.primaryContainer.withValues(alpha: focused ? 0.55 : 0.35)
        : Colors.transparent;
    final identical = node.status == EntryStatus.identical;

    return Semantics(
      selected: selected,
      label: '${node.name}, ${statusTooltip(node).toLowerCase()}',
      child: Container(
        color: background,
        foregroundDecoration: cursor && focused
            ? BoxDecoration(
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.8)),
              )
            : null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTapDown: onTapDown,
            onTap: () {},
            onSecondaryTapDown: onSecondaryTapDown,
            canRequestFocus: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _pane(context, Side.left)),
                VerticalDivider(width: 1, color: divider),
                SizedBox(
                  width: gutterWidth,
                  child: Tooltip(
                    message: statusTooltip(node),
                    child: Icon(
                      statusIcon(node.status),
                      size: compact ? 14 : 15,
                      color: identical
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                          : _statusColor(scheme),
                    ),
                  ),
                ),
                VerticalDivider(width: 1, color: divider),
                Expanded(child: _pane(context, Side.right)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pane(BuildContext context, Side side) {
    final scheme = Theme.of(context).colorScheme;
    final left = side == Side.left;
    final indent = 10.0 + depth * 18;

    if (!node.existsOn(side)) {
      return Container(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
        padding: EdgeInsets.only(left: indent + 40),
        alignment: Alignment.centerLeft,
        child: Text(
          '— missing —',
          style: TextStyle(
            fontSize: 11.5,
            fontStyle: FontStyle.italic,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ),
      );
    }

    final muted = node.status == EntryStatus.identical;
    final color = muted ? scheme.onSurfaceVariant : _statusColor(scheme);
    final isFolder = node.isDirectoryOn(side);
    final size = left ? node.leftSize : node.rightSize;
    final time = left ? node.leftModified : node.rightModified;
    final metaStyle = TextStyle(
        fontSize: 11.5,
        color: scheme.onSurfaceVariant.withValues(alpha: muted ? 0.75 : 1));

    final guide = scheme.outlineVariant.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 12),
      child: Row(
        children: [
          for (var i = 0; i < depth; i++)
            SizedBox(
              width: 18,
              child: Center(child: Container(width: 1, color: guide)),
            ),
          // Empty folders have nothing to open.
          if (node.isDirectory && node.children.isNotEmpty)
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
            )
          else
            const SizedBox(width: 18),
          const SizedBox(width: 4),
          Icon(
            isFolder
                ? (expanded && node.children.isNotEmpty
                    ? Icons.folder_open_outlined
                    : Icons.folder_outlined)
                : Icons.insert_drive_file_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 7),
          // Name and badges share what is left; the size and date columns
          // keep fixed widths so they line up from row to row.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ),
                if (node.isDirectory && left) ...[
                  if (node.modifiedCount > 0)
                    _CountBadge(
                        count: node.modifiedCount, color: palette.modified),
                  if (node.onlyLeftCount > 0)
                    _CountBadge(
                        count: node.onlyLeftCount, color: palette.removed),
                  if (node.onlyRightCount > 0)
                    _CountBadge(
                        count: node.onlyRightCount, color: palette.added),
                ],
                if (node.isTypeConflict)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(isFolder ? 'folder' : 'file',
                        style: metaStyle.copyWith(
                            fontStyle: FontStyle.italic)),
                  ),
                if (!node.isDirectory &&
                    node.status == EntryStatus.modified &&
                    !left) ...[
                  if ((node.addedLines ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('+${node.addedLines}',
                          style: monoStyle.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: palette.added)),
                    ),
                  if ((node.removedLines ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('−${node.removedLines}',
                          style: monoStyle.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: palette.removed)),
                    ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: sizeColWidth,
            child: Text(formatSize(size),
                textAlign: TextAlign.right,
                maxLines: 1,
                style: isFolder
                    ? metaStyle.copyWith(
                        color: metaStyle.color!.withValues(alpha: 0.6))
                    : metaStyle),
          ),
          SizedBox(
            width: timeColWidth,
            child: Text(formatTime(time, dateStyle),
                textAlign: TextAlign.right, maxLines: 1, style: metaStyle),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(formatCount(count),
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
