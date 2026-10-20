/// The DeltaView mark ("Split Delta"): two panes share one Δ, and the Δ
/// swaps colour where it crosses the seam. Drawn with a [CustomPainter] so
/// it is crisp at any size; the geometry mirrors assets/brand/delta_view.svg
/// on a 1024-unit canvas. Change the look here and it changes everywhere
/// the mark appears.
library;

import 'package:flutter/material.dart';

/// The brand mark at [size] logical pixels square. [AppLogo.glyph] is the
/// bare two-tone Δ without the rounded body, for small or inline uses.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 48}) : glyph = false;

  const AppLogo.glyph({super.key, this.size = 48}) : glyph = true;

  final double size;
  final bool glyph;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'DeltaView',
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: glyph ? const _GlyphPainter() : const _MarkPainter(),
        ),
      ),
    );
  }
}

const _indigo = Color(0xFF6366F1);
const _indigoDeep = Color(0xFF4F46E5);
const _pale = Color(0xFFE0E7FF);
const _paleDeep = Color(0xFFC7D2FE);
const _lavender = Color(0xFFA5B4FC);

/// The SVG canvas is 1024 units; every painter scales from that.
const _canvas = 1024.0;

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _canvas, size.height / _canvas);

    final body = RRect.fromLTRBR(100, 100, 924, 924, const Radius.circular(184));
    const leftPane = Rect.fromLTRB(0, 0, 512, _canvas);
    const rightPane = Rect.fromLTRB(512, 0, _canvas, _canvas);

    // Both gradients run top to bottom over the body, like the SVG's
    // userSpaceOnUse gradients.
    final indigo = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_indigo, _indigoDeep],
      ).createShader(body.outerRect);
    final pale = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_pale, _paleDeep],
      ).createShader(body.outerRect);

    final delta = Path()
      ..moveTo(512, 224)
      ..lineTo(824, 768)
      ..lineTo(200, 768)
      ..close();

    canvas.clipRRect(body);
    // The pane clips are not anti-aliased so the two halves meet at the
    // seam without a hairline showing through.
    canvas.save();
    canvas.clipRect(leftPane, doAntiAlias: false);
    canvas.drawRect(body.outerRect, indigo);
    canvas.drawPath(delta, pale);
    canvas.restore();

    canvas.save();
    canvas.clipRect(rightPane, doAntiAlias: false);
    canvas.drawRect(body.outerRect, pale);
    canvas.drawPath(delta, indigo);
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _canvas, size.height / _canvas);

    final delta = Path()
      ..moveTo(512, 72)
      ..lineTo(952, 952)
      ..lineTo(72, 952)
      ..close();

    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(0, 0, 512, _canvas), doAntiAlias: false);
    canvas.drawPath(delta, Paint()..color = _indigo);
    canvas.restore();

    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(512, 0, _canvas, _canvas),
        doAntiAlias: false);
    canvas.drawPath(delta, Paint()..color = _lavender);
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => false;
}
