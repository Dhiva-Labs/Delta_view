/// The narrow strip between the two panes: Meld-style bands that link each
/// change on the left to its counterpart on the right, with buttons that
/// copy a change across (or, with Shift held, delete it).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../diff/change_blocks.dart';
import '../../diff/line_diff.dart';
import '../../theme.dart';
import '../shortcuts/app_shortcuts.dart';

/// Where one change block sits on each side, in gutter coordinates.
class BandGeometry {
  const BandGeometry({
    required this.index,
    required this.block,
    required this.leftTop,
    required this.leftBottom,
    required this.rightTop,
    required this.rightBottom,
  });

  /// Index of the block in the diff.
  final int index;
  final ChangeBlock block;
  final double leftTop;
  final double leftBottom;
  final double rightTop;
  final double rightBottom;
}

class ConnectorGutter extends StatefulWidget {
  const ConnectorGutter({
    super.key,
    required this.bands,
    required this.currentBlock,
    required this.onCopy,
    required this.onDelete,
    this.canEditLeft = true,
    this.canEditRight = true,
  });

  static const width = 52.0;

  final List<BandGeometry> bands;
  final int currentBlock;

  /// Copies block `index` across: left → right when `toRight`.
  final void Function(int index, {required bool toRight}) onCopy;

  /// Deletes one side of block `index`.
  final void Function(int index, {required bool left}) onDelete;

  final bool canEditLeft;
  final bool canEditRight;

  @override
  State<ConnectorGutter> createState() => _ConnectorGutterState();
}

class _ConnectorGutterState extends State<ConnectorGutter> {
  bool _shift = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Watches Shift (without consuming any key) to swap the copy arrows
  /// for delete buttons, as Meld does.
  bool _onKey(KeyEvent event) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift != _shift && mounted) setState(() => _shift = shift);
    return false;
  }

  BandGeometry? _bandAt(Offset position) {
    final t = (position.dx / ConnectorGutter.width).clamp(0.0, 1.0);
    for (final band in widget.bands) {
      final top = band.leftTop + (band.rightTop - band.leftTop) * t;
      final bottom = band.leftBottom + (band.rightBottom - band.leftBottom) * t;
      if (position.dy >= top - 3 && position.dy <= bottom + 3) return band;
    }
    return null;
  }

  Future<void> _showMenu(TapUpDetails details) async {
    final band = _bandAt(details.localPosition);
    if (band == null) return;
    final block = band.block;
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(details.globalPosition.dx,
          details.globalPosition.dy, details.globalPosition.dx, 0),
      items: [
        PopupMenuItem(
          value: 0,
          enabled: widget.canEditRight,
          child: _MenuRow(Icons.arrow_forward, 'Copy to the right',
              AppAction.copyToRight.keyLabel),
        ),
        PopupMenuItem(
          value: 1,
          enabled: widget.canEditLeft,
          child: _MenuRow(Icons.arrow_back, 'Copy to the left',
              AppAction.copyToLeft.keyLabel),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 2,
          enabled: widget.canEditLeft && block.hasLeft,
          child: const _MenuRow(Icons.close, 'Delete on the left', null),
        ),
        PopupMenuItem(
          value: 3,
          enabled: widget.canEditRight && block.hasRight,
          child: const _MenuRow(Icons.close, 'Delete on the right', null),
        ),
      ],
    );
    switch (choice) {
      case 0:
        widget.onCopy(band.index, toRight: true);
      case 1:
        widget.onCopy(band.index, toRight: false);
      case 2:
        widget.onDelete(band.index, left: true);
      case 3:
        widget.onDelete(band.index, left: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      const button = 18.0;
      // Centred on the visible part of the band, so a tall change that is
      // scrolled half out of view keeps its button on screen.
      double place(double top, double bottom) {
        final visibleTop = math.max(top, 0.0);
        final visibleBottom = math.min(bottom, height);
        final y = visibleBottom > visibleTop
            ? (visibleTop + visibleBottom) / 2 - button / 2
            : (top + bottom) / 2 - button / 2;
        return math.max(0.0, math.min(y, height - button));
      }

      final buttons = <Widget>[];
      for (final band in widget.bands) {
        final block = band.block;
        if (band.leftBottom < 0 && band.rightBottom < 0) continue;
        if (band.leftTop > height && band.rightTop > height) continue;
        final current = band.index == widget.currentBlock;
        // Left button acts on (or from) the left side.
        final leftDelete = _shift;
        final leftEnabled = leftDelete
            ? widget.canEditLeft && block.hasLeft
            : widget.canEditRight;
        buttons.add(Positioned(
          left: 2,
          top: place(band.leftTop, band.leftBottom),
          child: _BandButton(
            icon: leftDelete ? Icons.close : Icons.arrow_forward,
            tooltip: leftDelete
                ? 'Delete this change on the left'
                : 'Copy to the right (${AppAction.copyToRight.keyLabel})\n'
                    'Shift-click to delete it on the left',
            color: _kindColor(palette, block.kind),
            emphasized: current,
            onPressed: !leftEnabled
                ? null
                : leftDelete
                    ? () => widget.onDelete(band.index, left: true)
                    : () => widget.onCopy(band.index, toRight: true),
          ),
        ));
        final rightEnabled =
            _shift ? widget.canEditRight && block.hasRight : widget.canEditLeft;
        buttons.add(Positioned(
          right: 2,
          top: place(band.rightTop, band.rightBottom),
          child: _BandButton(
            icon: _shift ? Icons.close : Icons.arrow_back,
            tooltip: _shift
                ? 'Delete this change on the right'
                : 'Copy to the left (${AppAction.copyToLeft.keyLabel})\n'
                    'Shift-click to delete it on the right',
            color: _kindColor(palette, block.kind),
            emphasized: current,
            onPressed: !rightEnabled
                ? null
                : _shift
                    ? () => widget.onDelete(band.index, left: false)
                    : () => widget.onCopy(band.index, toRight: false),
          ),
        ));
      }

      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: _showMenu,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BandPainter(
                  bands: widget.bands,
                  palette: palette,
                  currentBlock: widget.currentBlock,
                ),
              ),
            ),
            ...buttons,
          ],
        ),
      );
    });
  }
}

Color _kindColor(DiffPalette palette, DiffRowKind kind) => switch (kind) {
      DiffRowKind.added => palette.added,
      DiffRowKind.removed => palette.removed,
      _ => palette.modified,
    };

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, this.keys);

  final IconData icon;
  final String label;
  final String? keys;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16),
      const SizedBox(width: 10),
      Expanded(child: Text(label)),
      if (keys != null)
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Text(keys!,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
    ]);
  }
}

class _BandButton extends StatelessWidget {
  const _BandButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.emphasized,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final bool emphasized;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: emphasized ? color : scheme.surface,
        shape: CircleBorder(
            side: BorderSide(
                color: color.withValues(alpha: enabled ? 0.9 : 0.3))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 18,
            height: 18,
            child: Icon(icon,
                size: 12,
                color: emphasized
                    ? scheme.surface
                    : color.withValues(alpha: enabled ? 1 : 0.35)),
          ),
        ),
      ),
    );
  }
}

class _BandPainter extends CustomPainter {
  _BandPainter({
    required this.bands,
    required this.palette,
    required this.currentBlock,
  });

  final List<BandGeometry> bands;
  final DiffPalette palette;
  final int currentBlock;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final w = size.width;
    final fill = Paint();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final band in bands) {
      if (band.leftBottom < 0 && band.rightBottom < 0) continue;
      if (band.leftTop > size.height && band.rightTop > size.height) continue;
      final kind = band.block.kind;
      final color = _kindColor(palette, kind);
      final current = band.index == currentBlock;
      fill.color = palette.rowBackground(kind).withValues(
          alpha: (palette.rowBackground(kind).a * (current ? 2.4 : 1.6))
              .clamp(0.0, 1.0));
      stroke.color = color.withValues(alpha: current ? 0.9 : 0.55);

      // Top edge from the left block start to the right block start, as an
      // S-curve; the bottom edge likewise; filled in between.
      final top = Path()
        ..moveTo(0, band.leftTop)
        ..cubicTo(w / 2, band.leftTop, w / 2, band.rightTop, w, band.rightTop);
      final bottom = Path()
        ..moveTo(0, band.leftBottom)
        ..cubicTo(w / 2, band.leftBottom, w / 2, band.rightBottom, w,
            band.rightBottom);
      final area = Path()
        ..moveTo(0, band.leftTop)
        ..cubicTo(w / 2, band.leftTop, w / 2, band.rightTop, w, band.rightTop)
        ..lineTo(w, band.rightBottom)
        ..cubicTo(
            w / 2, band.rightBottom, w / 2, band.leftBottom, 0, band.leftBottom)
        ..close();
      canvas.drawPath(area, fill);
      canvas.drawPath(top, stroke);
      canvas.drawPath(bottom, stroke);
    }
  }

  @override
  bool shouldRepaint(_BandPainter old) =>
      old.bands != bands ||
      old.palette != palette ||
      old.currentBlock != currentBlock;
}
