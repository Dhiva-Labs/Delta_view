/// Shared horizontal scrolling for the view-mode rows: every cell of both
/// panes paints its text shifted by one offset, so the panes scroll
/// sideways together without rebuilding or relaying out any row.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Lays its child out at its natural width and paints it shifted left by
/// [offset], clipped to its own box. Only repaints when the offset moves.
class HorizontalShift extends SingleChildRenderObjectWidget {
  const HorizontalShift({super.key, required this.offset, super.child});

  final ValueListenable<double> offset;

  @override
  RenderHorizontalShift createRenderObject(BuildContext context) =>
      RenderHorizontalShift(offset);

  @override
  void updateRenderObject(
          BuildContext context, RenderHorizontalShift renderObject) =>
      renderObject.offset = offset;
}

class RenderHorizontalShift extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderHorizontalShift(this._offset);

  ValueListenable<double> _offset;
  set offset(ValueListenable<double> value) {
    if (identical(value, _offset)) return;
    if (attached) {
      _offset.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _offset = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _offset.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void performLayout() {
    size = constraints.biggest.isFinite
        ? constraints.biggest
        : constraints.constrain(Size.zero);
    child?.layout(
      BoxConstraints(maxHeight: size.height),
      parentUsesSize: false,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    context.pushClipRect(needsCompositing, offset, Offset.zero & size,
        (context, offset) {
      context.paintChild(child, offset + Offset(-_offset.value, 0));
    });
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(-_offset.value, 0),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(-_offset.value, 0, 0, 1);
  }
}

/// A thin horizontal scrollbar for an offset kept in a [ValueNotifier].
class HorizontalScrollbar extends StatelessWidget {
  const HorizontalScrollbar({
    super.key,
    required this.offset,
    required this.contentWidth,
  });

  final ValueNotifier<double> offset;
  final double contentWidth;

  static const height = 10.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = constraints.maxWidth;
      final max = contentWidth - viewport;
      if (max <= 0) return const SizedBox(height: height);
      final thumb = (viewport * viewport / contentWidth).clamp(32.0, viewport);
      final travel = viewport - thumb;
      void moveBy(double dx) {
        offset.value =
            (offset.value + dx * max / travel).clamp(0.0, max).toDouble();
      }

      return SizedBox(
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => moveBy(d.delta.dx),
          onTapDown: (d) {
            final at = offset.value / max * travel;
            if (d.localPosition.dx < at) {
              offset.value = (offset.value - viewport).clamp(0.0, max);
            } else if (d.localPosition.dx > at + thumb) {
              offset.value = (offset.value + viewport).clamp(0.0, max);
            }
          },
          child: ValueListenableBuilder<double>(
            valueListenable: offset,
            builder: (context, value, _) => CustomPaint(
              painter: _ThumbPainter(
                start: value.clamp(0.0, max) / max * travel,
                length: thumb,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter({
    required this.start,
    required this.length,
    required this.color,
  });

  final double start;
  final double length;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(start + 2, 3, length - 4, size.height - 5),
        const Radius.circular(3),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) =>
      old.start != start || old.length != length || old.color != color;
}

/// The sideways scroll a pointer signal asks for: a horizontal wheel or
/// touchpad swipe, or a vertical wheel with Shift held. Zero otherwise.
double horizontalScrollDelta(PointerSignalEvent event) {
  if (event is! PointerScrollEvent) return 0;
  final shift = HardwareKeyboard.instance.isShiftPressed;
  if (shift && event.kind == PointerDeviceKind.mouse) {
    return event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
  }
  return event.scrollDelta.dx;
}
