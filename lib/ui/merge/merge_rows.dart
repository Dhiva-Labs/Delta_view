/// The pieces of the merge view's list: one aligned row across the panes,
/// the inline editor for a chunk being edited by hand, and the change map.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../merge/merge_document.dart';
import '../../theme.dart';
import 'merge_layout.dart';

const mergeRowExtent = 22.0;
const mergeGutterWidth = 30.0;

/// Colours for chunks, worked out once per build.
class MergeColors {
  MergeColors._(this.palette, this.scheme);

  factory MergeColors.of(BuildContext context) =>
      MergeColors._(DiffPalette.of(context), Theme.of(context).colorScheme);

  final DiffPalette palette;
  final ColorScheme scheme;

  Color get filler => scheme.surfaceContainerHighest.withValues(alpha: 0.25);

  /// Background of the left or right pane: tinted where that side changed.
  Color side(MergeChunk chunk, {required bool left}) => switch (chunk.kind) {
        MergeChunkKind.unchanged => Colors.transparent,
        MergeChunkKind.conflict => palette.removedBg,
        MergeChunkKind.leftOnly =>
          left ? palette.modifiedBg : Colors.transparent,
        MergeChunkKind.rightOnly =>
          left ? Colors.transparent : palette.modifiedBg,
        MergeChunkKind.bothSame => palette.modifiedBg,
      };

  Color base(MergeChunk chunk) => chunk.isChange
      ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
      : Colors.transparent;

  /// Merged pane: red while a conflict is open, green once someone chose,
  /// amber for changes merged automatically.
  Color merged(MergeChunk chunk, ChunkState state) =>
      switch (state.resolution) {
        Resolution.unresolved => palette.removedBg,
        Resolution.automatic =>
          chunk.isChange ? palette.modifiedBg : Colors.transparent,
        _ => palette.addedBg,
      };

  /// The bar on the merged pane's edge that says what state a chunk is in.
  Color? stripe(MergeChunk chunk, ChunkState state) =>
      switch (state.resolution) {
        Resolution.unresolved => palette.removed,
        Resolution.automatic => chunk.isChange ? palette.modified : null,
        _ => palette.added,
      };
}

/// Width of a line-number gutter that fits [lines].
double lineNumberWidth(int lines) => 14.0 + 8.0 * math.max(2, '$lines'.length);

/// The callbacks rows use to act on their chunk.
class MergeRowActions {
  const MergeRowActions({
    required this.select,
    required this.edit,
    required this.take,
    required this.append,
    required this.contextMenu,
  });

  final void Function(int chunk) select;
  final void Function(int chunk) edit;
  final void Function(int chunk, Resolution resolution) take;
  final void Function(int chunk, {required bool left}) append;
  final void Function(int chunk, Offset globalPosition) contextMenu;
}

/// Row [row] of chunk [chunk]: the same height in every pane, so the three
/// versions line up and scroll as one.
class MergeLineRow extends StatelessWidget {
  const MergeLineRow({
    super.key,
    required this.layout,
    required this.chunk,
    required this.row,
    required this.selected,
    required this.colors,
    required this.numberWidth,
    required this.actions,
  });

  final MergeLayout layout;
  final int chunk;
  final int row;
  final bool selected;
  final MergeColors colors;
  final double numberWidth;
  final MergeRowActions actions;

  MergeDocument get _doc => layout.document;

  @override
  Widget build(BuildContext context) {
    final c = _doc.chunks[chunk];
    final state = _doc.state(chunk);
    final first = row == 0;
    final last = row == layout.rowsOf(chunk) - 1;
    final unresolved = !state.isResolved;

    final mergedHint = first && state.lines.isEmpty
        ? (unresolved
            ? 'unresolved: take left, right or both'
            : c.isChange || state.resolution == Resolution.edited
                ? 'nothing here (lines removed)'
                : null)
        : null;

    Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (layout.showBase) ...[
          Expanded(
            child: _LineCell(
              lines: c.base,
              row: row,
              firstNumber: layout.baseLineOf(chunk),
              numberWidth: numberWidth,
              background: colors.base(c),
              filler: colors.filler,
              muted: true,
            ),
          ),
          VerticalDivider(width: 1, color: colors.scheme.outlineVariant),
        ],
        Expanded(
          child: _LineCell(
            lines: c.left,
            row: row,
            firstNumber: layout.leftLineOf(chunk),
            numberWidth: numberWidth,
            background: colors.side(c, left: true),
            filler: colors.filler,
          ),
        ),
        _Gutter(
          visible: first && c.isChange && _differs(state, c.left),
          icon: Icons.arrow_forward_rounded,
          tooltip: 'Take left · shift-click adds it below',
          onPressed: () => HardwareKeyboard.instance.isShiftPressed
              ? actions.append(chunk, left: true)
              : actions.take(chunk, Resolution.left),
        ),
        Expanded(
          child: _LineCell(
            lines: state.lines,
            row: row,
            firstNumber: unresolved ? null : layout.mergedLineOf(chunk),
            numberWidth: numberWidth,
            background: colors.merged(c, state),
            filler: colors.filler,
            stripe: colors.stripe(c, state),
            muted: unresolved,
            hint: mergedHint,
            badge:
                first && (c.isChange || state.resolution == Resolution.edited)
                    ? state.resolution
                    : null,
            onDoubleTap: () => actions.edit(chunk),
          ),
        ),
        _Gutter(
          visible: first && c.isChange && _differs(state, c.right),
          icon: Icons.arrow_back_rounded,
          tooltip: 'Take right · shift-click adds it below',
          onPressed: () => HardwareKeyboard.instance.isShiftPressed
              ? actions.append(chunk, left: false)
              : actions.take(chunk, Resolution.right),
        ),
        Expanded(
          child: _LineCell(
            lines: c.right,
            row: row,
            firstNumber: layout.rightLineOf(chunk),
            numberWidth: numberWidth,
            background: colors.side(c, left: false),
            filler: colors.filler,
          ),
        ),
      ],
    );

    if (selected) {
      final edge = BorderSide(
        color: colors.scheme.primary.withValues(alpha: 0.8),
        width: 1.5,
      );
      content = Container(
        foregroundDecoration: BoxDecoration(
          border: Border(
            left: edge,
            right: edge,
            top: first ? edge : BorderSide.none,
            bottom: last ? edge : BorderSide.none,
          ),
        ),
        child: content,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => actions.select(chunk),
      onSecondaryTapUp: (details) =>
          actions.contextMenu(chunk, details.globalPosition),
      child: content,
    );
  }

  static bool _differs(ChunkState state, List<String> side) {
    if (!state.isResolved) return true;
    final lines = state.lines;
    if (lines.length != side.length) return true;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] != side[i]) return true;
    }
    return false;
  }
}

class _LineCell extends StatelessWidget {
  const _LineCell({
    required this.lines,
    required this.row,
    required this.firstNumber,
    required this.numberWidth,
    required this.background,
    required this.filler,
    this.stripe,
    this.muted = false,
    this.hint,
    this.badge,
    this.onDoubleTap,
  });

  final List<String> lines;
  final int row;

  /// Zero-based line number of the chunk's first line in this pane; null
  /// hides the numbers.
  final int? firstNumber;
  final double numberWidth;
  final Color background;
  final Color filler;
  final Color? stripe;
  final bool muted;
  final String? hint;
  final Resolution? badge;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final has = row < lines.length;
    final numberStyle = monoStyle.copyWith(
      fontSize: 11.5,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
    Widget text;
    if (has) {
      text = Text(
        lines[row],
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: muted
            ? monoStyle.copyWith(
                fontStyle: FontStyle.italic,
                color: scheme.onSurface.withValues(alpha: 0.5),
              )
            : monoStyle,
      );
    } else if (hint != null) {
      text = Text(
        hint!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontStyle: FontStyle.italic,
          color: scheme.onSurfaceVariant,
        ),
      );
    } else {
      text = const SizedBox.shrink();
    }

    return GestureDetector(
      onDoubleTap: onDoubleTap,
      child: Container(
        color: has ? background : Color.alphaBlend(filler, background),
        child: Row(
          children: [
            Container(width: 3, color: stripe ?? Colors.transparent),
            SizedBox(
              width: numberWidth - 3,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  has && firstNumber != null ? '${firstNumber! + row + 1}' : '',
                  textAlign: TextAlign.right,
                  style: numberStyle,
                ),
              ),
            ),
            Expanded(child: text),
            if (badge != null) _ResolutionBadge(resolution: badge!),
          ],
        ),
      ),
    );
  }
}

class _ResolutionBadge extends StatelessWidget {
  const _ResolutionBadge({required this.resolution});

  final Resolution resolution;

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final (text, color) = switch (resolution) {
      Resolution.unresolved => ('conflict', palette.removed),
      Resolution.automatic => ('auto', palette.modified),
      Resolution.left => ('left', palette.added),
      Resolution.right => ('right', palette.added),
      Resolution.leftThenRight => ('left + right', palette.added),
      Resolution.rightThenLeft => ('right + left', palette.added),
      Resolution.base => ('base', palette.added),
      Resolution.edited => ('edited', palette.added),
    };
    return Container(
      margin: const EdgeInsets.only(left: 6, right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({
    required this.visible,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final bool visible;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: mergeGutterWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        ),
        child: visible
            ? Tooltip(
                message: tooltip,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onPressed,
                  child: Center(
                    child: Icon(icon, size: 15, color: scheme.primary),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// A chunk being edited by hand: the sides stay visible, the merged pane
/// becomes a text field.
class MergeChunkEditor extends StatelessWidget {
  const MergeChunkEditor({
    super.key,
    required this.layout,
    required this.chunk,
    required this.colors,
    required this.numberWidth,
    required this.controller,
    required this.focusNode,
    required this.onApply,
    required this.onCancel,
  });

  final MergeLayout layout;
  final int chunk;
  final MergeColors colors;
  final double numberWidth;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onApply;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = layout.document.chunks[chunk];
    final rows = layout.rowsOf(chunk);
    final scheme = colors.scheme;

    Widget sideLines(
      List<String> lines,
      int first,
      Color bg, {
      bool muted = false,
    }) {
      return Column(
        children: [
          for (var r = 0; r < rows; r++)
            SizedBox(
              height: mergeRowExtent,
              child: _LineCell(
                lines: lines,
                row: r,
                firstNumber: first,
                numberWidth: numberWidth,
                background: bg,
                filler: colors.filler,
                muted: muted,
              ),
            ),
        ],
      );
    }

    final editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): onApply,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): onApply,
        const SingleActivator(LogicalKeyboardKey.escape): onCancel,
      },
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.primary, width: 1.5),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: null,
          expands: true,
          style: monoStyle,
          strutStyle: const StrutStyle(
            fontSize: 13,
            height: mergeRowExtent / 13,
            forceStrutHeight: true,
          ),
          textAlignVertical: TextAlignVertical.top,
          onTapOutside: (_) => onApply(),
          decoration: const InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ),
    );

    return Column(
      children: [
        SizedBox(
          height: rows * mergeRowExtent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (layout.showBase) ...[
                Expanded(
                  child: sideLines(
                    c.base,
                    layout.baseLineOf(chunk),
                    colors.base(c),
                    muted: true,
                  ),
                ),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
              ],
              Expanded(
                child: sideLines(
                  c.left,
                  layout.leftLineOf(chunk),
                  colors.side(c, left: true),
                ),
              ),
              const SizedBox(width: mergeGutterWidth),
              Expanded(child: editor),
              const SizedBox(width: mergeGutterWidth),
              Expanded(
                child: sideLines(
                  c.right,
                  layout.rightLineOf(chunk),
                  colors.side(c, left: false),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: MergeLayout.editorChrome,
          color: scheme.primaryContainer.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Editing by hand · Ctrl+Enter applies · Esc cancels',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A thin strip beside the list with a mark for every change, so the whole
/// file's conflicts are visible at once. Clicking jumps there.
class MergeChangeMap extends StatelessWidget {
  const MergeChangeMap({
    super.key,
    required this.layout,
    required this.colors,
    required this.onJump,
  });

  final MergeLayout layout;
  final MergeColors colors;
  final void Function(int chunk) onJump;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapDown: (details) {
          if (layout.totalExtent <= 0) return;
          final fraction = details.localPosition.dy / constraints.maxHeight;
          onJump(layout.chunkAtOffset(fraction * layout.totalExtent));
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: CustomPaint(
            size: Size(14, constraints.maxHeight),
            painter: _ChangeMapPainter(layout, colors),
          ),
        ),
      ),
    );
  }
}

class _ChangeMapPainter extends CustomPainter {
  _ChangeMapPainter(this.layout, this.colors);

  final MergeLayout layout;
  final MergeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = layout.totalExtent;
    if (total <= 0) return;
    final doc = layout.document;
    final paint = Paint();
    for (var i = 0; i < doc.chunks.length; i++) {
      final chunk = doc.chunks[i];
      final state = doc.state(i);
      // Clean chunks only show once edited by hand.
      final color = colors.stripe(chunk, state);
      if (color == null) continue;
      paint.color = color;
      final top = layout.offsetOf(i) / total * size.height;
      final height = math.max(3.0, layout.heightOf(i) / total * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3, top, size.width - 6, height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ChangeMapPainter old) => true;
}
