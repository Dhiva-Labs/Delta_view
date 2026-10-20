/// The overview strip beside the panes: where the changes are in the whole
/// file, and a box for the part on screen that can be dragged to scroll.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../diff/line_diff.dart';
import '../../theme.dart';

/// A change in the minimap's coordinate space.
typedef MinimapMark = ({double start, double end, DiffRowKind kind});

class Minimap extends StatefulWidget {
  const Minimap({
    super.key,
    required this.total,
    required this.marks,
    required this.viewStart,
    required this.viewExtent,
    required this.onScrollTo,
  });

  static const width = 16.0;

  /// Length of the whole content, in the same units as everything else.
  final double total;
  final List<MinimapMark> marks;

  /// The part on screen.
  final double viewStart;
  final double viewExtent;

  /// Asks for the view to start at this position.
  final ValueChanged<double> onScrollTo;

  @override
  State<Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<Minimap> {
  /// Where in the view box the pointer grabbed it, in content units.
  double _grab = 0;
  bool _dragging = false;

  double _toContent(double dy, double height) =>
      height <= 0 ? 0 : dy / height * widget.total;

  void _start(Offset local, double height) {
    final at = _toContent(local.dy, height);
    final inBox =
        at >= widget.viewStart && at <= widget.viewStart + widget.viewExtent;
    // Grabbing the box drags it from where it was held; clicking outside
    // centres the view there first.
    _grab = inBox ? at - widget.viewStart : widget.viewExtent / 2;
    setState(() => _dragging = true);
    if (!inBox) widget.onScrollTo(at - _grab);
  }

  void _update(Offset local, double height) =>
      widget.onScrollTo(_toContent(local.dy, height) - _grab);

  void _end() => setState(() => _dragging = false);

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: Minimap.width,
      child: LayoutBuilder(builder: (context, constraints) {
        final height = constraints.maxHeight;
        return MouseRegion(
          cursor:
              _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragDown: (d) => _start(d.localPosition, height),
            onVerticalDragUpdate: (d) => _update(d.localPosition, height),
            onVerticalDragEnd: (_) => _end(),
            onVerticalDragCancel: _end,
            child: CustomPaint(
              size: Size(Minimap.width, height),
              painter: _MinimapPainter(
                total: widget.total,
                marks: widget.marks,
                viewStart: widget.viewStart,
                viewExtent: widget.viewExtent,
                palette: palette,
                track: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                box:
                    scheme.onSurface.withValues(alpha: _dragging ? 0.16 : 0.09),
                boxBorder:
                    scheme.onSurface.withValues(alpha: _dragging ? 0.55 : 0.32),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.total,
    required this.marks,
    required this.viewStart,
    required this.viewExtent,
    required this.palette,
    required this.track,
    required this.box,
    required this.boxBorder,
  });

  final double total;
  final List<MinimapMark> marks;
  final double viewStart;
  final double viewExtent;
  final DiffPalette palette;
  final Color track;
  final Color box;
  final Color boxBorder;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    if (total <= 0) return;
    final scale = size.height / total;
    final paint = Paint();
    for (final mark in marks) {
      paint.color = switch (mark.kind) {
        DiffRowKind.added => palette.added,
        DiffRowKind.removed => palette.removed,
        _ => palette.modified,
      };
      final top = mark.start * scale;
      final height = math.max(2.0, (mark.end - mark.start) * scale);
      canvas.drawRect(Rect.fromLTWH(3, top, size.width - 6, height), paint);
    }
    // The visible region, never thinner than a grabbable sliver.
    final top = (viewStart * scale).clamp(0.0, size.height);
    final height = math.max(6.0, viewExtent * scale);
    final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, math.min(top, size.height - height), size.width - 1,
            math.min(height, size.height)),
        const Radius.circular(3));
    canvas.drawRRect(rect, Paint()..color = box);
    canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = boxBorder);
  }

  @override
  bool shouldRepaint(_MinimapPainter old) =>
      old.total != total ||
      old.marks != marks ||
      old.viewStart != viewStart ||
      old.viewExtent != viewExtent ||
      old.palette != palette ||
      old.box != box ||
      old.boxBorder != boxBorder;
}
