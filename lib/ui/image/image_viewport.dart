/// Zoom and pan shared by every pane of the image compare view, and the
/// canvas widget that turns mouse and trackpad input into them.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Maps image (canvas) pixels to screen: `screen = offset + scale * pixel`.
/// One instance drives all panes, which is what keeps side-by-side panes
/// in sync: they each paint with the same transform in their own box.
class ImageViewport extends ChangeNotifier {
  static const minScale = 0.02;
  static const maxScale = 64.0;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _content = Size.zero;
  Size _view = Size.zero;

  /// While true the image refits whenever the pane changes size; any zoom
  /// or pan by the user turns it off.
  bool _fitting = true;

  /// Whether fitting may enlarge a small image past 100 %: only once the
  /// user asks for Fit explicitly.
  bool _upscale = false;

  double get scale => _scale;
  Offset get offset => _offset;
  Size get contentSize => _content;
  bool get isFitted => _fitting;

  /// Sets the canvas size (the larger of the two images); refits.
  set contentSize(Size size) {
    if (size == _content) return;
    _content = size;
    _fitting = true;
    _upscale = false;
    _applyFit();
  }

  /// Called by the canvas on layout.
  void updateViewSize(Size size) {
    if (size == _view) return;
    final old = _view;
    _view = size;
    if (_fitting || old.isEmpty) {
      _applyFit();
    } else {
      // Keep the point at the centre in the centre.
      _offset +=
          Offset((size.width - old.width) / 2, (size.height - old.height) / 2);
      notifyListeners();
    }
  }

  void fit() {
    _fitting = true;
    _upscale = true;
    _applyFit();
  }

  /// 100 %: one image pixel per logical pixel, centred.
  void actualSize() {
    _fitting = false;
    _scale = 1;
    _center();
    notifyListeners();
  }

  /// Fits [rect] (canvas pixels) into the view with some room around it.
  void showRect(Rect rect) {
    if (_view.isEmpty || rect.isEmpty) return;
    _fitting = false;
    final padded = rect.inflate(math.max(rect.width, rect.height) * 0.15 + 4);
    _scale = math
        .min(_view.width / padded.width, _view.height / padded.height)
        .clamp(minScale, maxScale);
    _offset = _view.center(Offset.zero) - padded.center * _scale;
    notifyListeners();
  }

  /// Zooms by [factor] keeping the canvas point under [focal] in place
  /// (the mouse cursor, or the view centre for keyboard zoom).
  void zoomAt(Offset focal, double factor) {
    final next = (_scale * factor).clamp(minScale, maxScale);
    if (next == _scale) return;
    _fitting = false;
    _offset = focal - (focal - _offset) * (next / _scale);
    _scale = next;
    notifyListeners();
  }

  void zoomCentered(double factor) => zoomAt(_view.center(Offset.zero), factor);

  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _fitting = false;
    _offset += delta;
    notifyListeners();
  }

  /// Canvas pixel → screen position in a pane.
  Rect toScreen(Rect canvasRect) => Rect.fromLTWH(
        _offset.dx + canvasRect.left * _scale,
        _offset.dy + canvasRect.top * _scale,
        canvasRect.width * _scale,
        canvasRect.height * _scale,
      );

  Offset toCanvas(Offset screen) => (screen - _offset) / _scale;

  void _applyFit() {
    if (_view.isEmpty || _content.isEmpty) {
      notifyListeners();
      return;
    }
    const margin = 24.0;
    final fit = math.min((_view.width - margin) / _content.width,
        (_view.height - margin) / _content.height);
    _scale = (_upscale ? fit : math.min(1.0, fit)).clamp(minScale, maxScale);
    _center();
    notifyListeners();
  }

  void _center() {
    _offset = Offset((_view.width - _content.width * _scale) / 2,
        (_view.height - _content.height * _scale) / 2);
  }
}

/// A pane that shows images through an [ImageViewport]: wheel zooms around
/// the cursor, dragging pans, and trackpad pinch and pan work too.
class ImageCanvas extends StatelessWidget {
  const ImageCanvas({
    super.key,
    required this.viewport,
    required this.painter,
    this.reportSize = true,
    this.onHover,
  });

  final ImageViewport viewport;
  final CustomPainter painter;

  /// Only one pane of several should drive the viewport's size.
  final bool reportSize;

  /// The canvas pixel under the mouse, or null when it leaves.
  final ValueChanged<Offset?>? onHover;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (reportSize) {
        // Layout cannot notify listeners mid-build; report after it.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => viewport.updateViewSize(size));
      }
      return ClipRect(
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(event,
                  (event) {
                final dy = (event as PointerScrollEvent).scrollDelta.dy;
                viewport.zoomAt(
                    event.localPosition, math.pow(1.0018, -dy).toDouble());
              });
            }
          },
          onPointerPanZoomUpdate: (event) {
            viewport.panBy(event.panDelta);
            if (event.scale != 1) {
              viewport.zoomAt(event.localPosition, 1 + (event.scale - 1) / 8);
            }
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            onHover: onHover == null
                ? null
                : (event) => onHover!(viewport.toCanvas(event.localPosition)),
            onExit: onHover == null ? null : (_) => onHover!(null),
            child: GestureDetector(
              onPanUpdate: (details) => viewport.panBy(details.delta),
              child: CustomPaint(
                size: size,
                painter: painter,
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// The grey and white squares behind transparent pixels.
class Checkerboard {
  static final _tiles = <Brightness, ui.Image>{};

  static ui.Image _tile(Brightness brightness) =>
      _tiles.putIfAbsent(brightness, () {
        final dark = brightness == Brightness.dark;
        final a = dark ? const Color(0xFF2B2F3A) : const Color(0xFFFFFFFF);
        final b = dark ? const Color(0xFF1F222B) : const Color(0xFFE3E5EC);
        const s = 8.0;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
            const Rect.fromLTWH(0, 0, s * 2, s * 2), Paint()..color = a);
        canvas.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..color = b);
        canvas.drawRect(const Rect.fromLTWH(s, s, s, s), Paint()..color = b);
        return recorder.endRecording().toImageSync(16, 16);
      });

  static void paint(Canvas canvas, Rect rect, Brightness brightness) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ImageShader(_tile(brightness), TileMode.repeated,
            TileMode.repeated, Matrix4.identity().storage,
            filterQuality: FilterQuality.none),
    );
  }
}

/// Draws [image] with its top-left at [origin] (canvas pixels), sharp when
/// zoomed in far enough to see single pixels, smooth otherwise.
void paintViewportImage(
    Canvas canvas, ImageViewport viewport, ui.Image image, Offset origin,
    {Paint? paint}) {
  final dest = viewport.toScreen(Rect.fromLTWH(
      origin.dx, origin.dy, image.width.toDouble(), image.height.toDouble()));
  final p = (paint ?? Paint())
    ..filterQuality =
        viewport.scale >= 2 ? FilterQuality.none : FilterQuality.medium;
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    dest,
    p,
  );
}
