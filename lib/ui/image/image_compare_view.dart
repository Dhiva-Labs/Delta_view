import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../compare/diff_side.dart';
import '../../theme.dart';
import '../file_diff_view.dart';
import '../shortcuts/app_shortcuts.dart';
import 'image_diff.dart';
import 'image_format.dart';
import 'image_viewport.dart';

export 'image_format.dart' show isImageFile;

/// Images larger than this many pixels are shown but not diffed pixel by
/// pixel: the buffers alone would take gigabytes.
const _maxDiffPixels = 64 * 1000 * 1000;

enum ImageCompareMode {
  sideBySide('Side by side', Icons.view_column_outlined),
  swipe('Swipe', Icons.compare),
  onion('Onion skin', Icons.layers_outlined),
  difference('Difference', Icons.difference_outlined);

  const ImageCompareMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Side-by-side, swipe, onion-skin and difference views of two images,
/// all sharing one zoom and pan.
class ImageCompareView extends StatefulWidget {
  const ImageCompareView({
    super.key,
    required this.left,
    required this.right,
    this.title,
    this.onBack,
  });

  final DiffSide left;
  final DiffSide right;
  final String? title;
  final VoidCallback? onBack;

  @override
  State<ImageCompareView> createState() => _ImageCompareViewState();
}

/// One side, read and decoded.
class _ImageSide {
  const _ImageSide({
    this.bytes,
    this.image,
    this.rgba,
    this.frames = 1,
    this.format = ImageFormat.unknown,
    this.error,
  });

  final Uint8List? bytes;
  final ui.Image? image;

  /// Premultiplied RGBA of the first frame; null when too big to diff.
  final RgbaImage? rgba;
  final int frames;
  final ImageFormat format;
  final String? error;

  bool get missing => bytes == null && error == null;
  bool get ok => image != null;

  String describe() {
    final image = this.image;
    return [
      format.label,
      if (image != null) '${image.width} × ${image.height}',
      if (bytes != null) formatByteSize(bytes!.length),
      if (frames > 1) '$frames frames (showing the first)',
    ].join('  ·  ');
  }
}

class _ImageCompareViewState extends State<ImageCompareView> {
  _ImageSide? _left;
  _ImageSide? _right;
  bool _textView = false;

  ImageCompareMode _mode = ImageCompareMode.sideBySide;
  ImageAlignment _alignment = ImageAlignment.topLeft;
  double _onion = 0.5;
  double _swipe = 0.5;
  double _tolerance = 0;

  ImageDiffAnalysis? _analysis;
  bool _analyzing = false;
  ui.Image? _mask;
  Timer? _maskTimer;

  /// Bumped on every new analysis or mask request so late isolate results
  /// for an older tolerance or alignment are dropped.
  int _generation = 0;

  Offset? _hover;
  final _viewport = ImageViewport();
  final _focus = FocusNode(debugLabel: 'image compare');

  bool get _sameSize =>
      _left?.image?.width == _right?.image?.width &&
      _left?.image?.height == _right?.image?.height;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _maskTimer?.cancel();
    _disposeImages();
    _viewport.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _disposeImages() {
    _left?.image?.dispose();
    _right?.image?.dispose();
    _mask?.dispose();
    _mask = null;
  }

  Future<void> _load() async {
    _generation++;
    setState(() {
      _disposeImages();
      _left = null;
      _right = null;
      _analysis = null;
    });
    final sides = await Future.wait([_read(widget.left), _read(widget.right)]);
    if (!mounted) {
      for (final s in sides) {
        s.image?.dispose();
      }
      return;
    }
    setState(() {
      _left = sides[0];
      _right = sides[1];
    });
    final l = sides[0].image, r = sides[1].image;
    if (l != null && r != null) {
      _viewport.contentSize = Size(math.max(l.width, r.width).toDouble(),
          math.max(l.height, r.height).toDouble());
      _analyze();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  static Future<_ImageSide> _read(DiffSide side) async {
    Uint8List? bytes;
    try {
      bytes = await side.read();
    } catch (e) {
      return _ImageSide(error: 'Could not read the file: $e');
    }
    if (bytes == null) return const _ImageSide();
    final format = sniffImageFormat(bytes);
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      RgbaImage? rgba;
      if (image.width * image.height <= _maxDiffPixels) {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null) {
          rgba = RgbaImage(image.width, image.height,
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        }
      }
      return _ImageSide(
        bytes: bytes,
        image: image,
        rgba: rgba,
        frames: codec.frameCount,
        format: format,
      );
    } catch (e) {
      return _ImageSide(
        bytes: bytes,
        format: format,
        error: format == ImageFormat.unknown
            ? 'This is not an image this app can read.'
            : 'The ${format.label} data is damaged or unsupported ($e).',
      );
    } finally {
      codec?.dispose();
    }
  }

  // ---- difference ----

  Future<void> _analyze() async {
    final l = _left?.rgba, r = _right?.rgba;
    if (l == null || r == null) return;
    final generation = ++_generation;
    setState(() => _analyzing = true);
    final analysis = await _analyzeInIsolate(l, r, _alignment);
    if (!mounted || generation != _generation) return;
    setState(() {
      _analysis = analysis;
      _analyzing = false;
    });
    _renderMask();
  }

  /// Static so the isolate closure captures only plain data.
  static Future<ImageDiffAnalysis> _analyzeInIsolate(
          RgbaImage l, RgbaImage r, ImageAlignment alignment) =>
      Isolate.run(() => analyzeImageDiff(l, r, alignment: alignment));

  static Future<Uint8List> _maskInIsolate(
          ImageDiffAnalysis analysis, int tolerance) =>
      Isolate.run(() => renderDiffMask(analysis, tolerance));

  void _scheduleMask() {
    _maskTimer?.cancel();
    _maskTimer = Timer(const Duration(milliseconds: 120), _renderMask);
  }

  Future<void> _renderMask() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final generation = ++_generation;
    final pixels = await _maskInIsolate(analysis, toleranceSteps(_tolerance));
    if (!mounted || generation != _generation) return;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, analysis.width, analysis.height,
        ui.PixelFormat.rgba8888, completer.complete);
    final mask = await completer.future;
    if (!mounted || generation != _generation) {
      mask.dispose();
      return;
    }
    setState(() {
      _mask?.dispose();
      _mask = mask;
    });
  }

  void _setAlignment(ImageAlignment alignment) {
    if (alignment == _alignment) return;
    setState(() {
      _alignment = alignment;
      _analysis = null;
    });
    _analyze();
  }

  Offset _origin(ui.Image image) {
    final size = _viewport.contentSize;
    final (x, y) = alignedOrigin(image.width, image.height, size.width.toInt(),
        size.height.toInt(), _alignment);
    return Offset(x.toDouble(), y.toDouble());
  }

  // ---- building ----

  String get _title {
    final l = widget.left.label, r = widget.right.label;
    return widget.title ?? (l == r ? l : '$l ↔ $r');
  }

  @override
  Widget build(BuildContext context) {
    if (_textView) return _textFallback(context);
    final left = _left, right = _right;
    if (left == null || right == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!left.ok || !right.ok) {
      return _ProblemView(
        title: _title,
        leftSide: widget.left,
        rightSide: widget.right,
        left: left,
        right: right,
        onBack: widget.onBack,
        onRetry: _load,
        onTextView: () => setState(() => _textView = true),
      );
    }

    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.zoomIn: () => _viewport.zoomCentered(1.25),
        AppAction.zoomOut: () => _viewport.zoomCentered(0.8),
        AppAction.zoomReset: _viewport.fit,
        AppAction.refresh: _load,
      }),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Column(
          children: [
            _header(context, left, right),
            _controls(context),
            _MetaRow(
              left: left,
              right: right,
              leftName: widget.left.description,
              rightName: widget.right.description,
            ),
            const Divider(),
            Expanded(
              child: Listener(
                onPointerDown: (_) => _focus.requestFocus(),
                child: _body(context, left.image!, right.image!),
              ),
            ),
            _statusBar(context, left, right),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, _ImageSide left, _ImageSide right) {
    final palette = DiffPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final analysis = _analysis;
    final tolerance = toleranceSteps(_tolerance);
    final (String text, Color color) = listEquals(left.bytes, right.bytes)
        ? ('Files are identical', palette.added)
        : analysis == null
            ? (
                _analyzing ? 'Comparing pixels…' : 'Not compared',
                scheme.onSurfaceVariant
              )
            : analysis.changedPixels(tolerance) == 0
                ? (
                    tolerance == 0
                        ? 'Same pixels, different files'
                        : 'No pixels differ beyond the tolerance',
                    palette.added
                  )
                : (
                    '${_percent(analysis.changedFraction(tolerance))} '
                        'of pixels differ',
                    palette.modified
                  );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Change files',
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          const SizedBox(width: 4),
          Icon(Icons.image_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 14),
          Flexible(child: _Pill(text: text, color: color)),
          if (!_sameSize) ...[
            const SizedBox(width: 8),
            Flexible(
              child: _Pill(
                text: 'Sizes differ',
                color: palette.modified,
                icon: Icons.aspect_ratio,
              ),
            ),
          ],
          const SizedBox(width: 16),
          SegmentedButton<ImageCompareMode>(
            showSelectedIcon: false,
            style:
                SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: [
              for (final m in ImageCompareMode.values)
                ButtonSegment(
                    value: m,
                    icon: Icon(m.icon, size: 16),
                    label: Text(m.label)),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Compare as text / binary',
            onPressed: () => setState(() => _textView = true),
            icon: const Icon(Icons.notes, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final analysis = _analysis;

    final modeControls = switch (_mode) {
      ImageCompareMode.sideBySide => Text('Both sides zoom and pan together.',
          style: small, overflow: TextOverflow.ellipsis),
      ImageCompareMode.swipe =>
        Text('Drag the divider to wipe between the images.', style: small),
      ImageCompareMode.onion => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Left', style: small),
            SizedBox(
              width: 220,
              child: Slider(
                value: _onion,
                onChanged: (v) => setState(() => _onion = v),
              ),
            ),
            Text('Right  ${(_onion * 100).round()} %', style: small),
          ],
        ),
      ImageCompareMode.difference => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Ignore pixels whose channels differ by less than '
                  'this much',
              child: Text('Tolerance', style: small),
            ),
            SizedBox(
              width: 180,
              child: Slider(
                value: _tolerance,
                max: 100,
                onChanged: (v) {
                  setState(() => _tolerance = v);
                  _scheduleMask();
                },
              ),
            ),
            SizedBox(
                width: 44,
                child: Text('${_tolerance.round()} %', style: small)),
            if (analysis != null) ...[
              const SizedBox(width: 8),
              Flexible(child: _differenceStats(context, analysis)),
            ],
          ],
        ),
    };

    final size = _viewport.contentSize;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 4),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child:
                  Align(alignment: Alignment.centerLeft, child: modeControls),
            ),
            if (!_sameSize) ...[
              Text('Align', style: small),
              const SizedBox(width: 6),
              SegmentedButton<ImageAlignment>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                      value: ImageAlignment.topLeft,
                      icon: Icon(Icons.north_west, size: 15),
                      tooltip: 'Align top-left corners'),
                  ButtonSegment(
                      value: ImageAlignment.center,
                      icon: Icon(Icons.filter_center_focus, size: 15),
                      tooltip: 'Align centres'),
                ],
                selected: {_alignment},
                onSelectionChanged: (s) => _setAlignment(s.first),
              ),
              const SizedBox(width: 12),
            ],
            ListenableBuilder(
              listenable: _viewport,
              builder: (context, _) => _ZoomControls(
                viewport: _viewport,
                enabled: !size.isEmpty,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _differenceStats(BuildContext context, ImageDiffAnalysis analysis) {
    final scheme = Theme.of(context).colorScheme;
    final tolerance = toleranceSteps(_tolerance);
    final changed = analysis.changedPixels(tolerance);
    final bounds = analysis.changedBounds(tolerance);
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            bounds == null
                ? 'No changed pixels'
                : '${_count(changed)} px (${_percent(changed / analysis.pixelCount)})'
                    '  ·  box ${bounds.width} × ${bounds.height} at '
                    '${bounds.left}, ${bounds.top}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (bounds != null)
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _viewport.showRect(Rect.fromLTRB(
                bounds.left.toDouble(),
                bounds.top.toDouble(),
                bounds.right.toDouble(),
                bounds.bottom.toDouble())),
            icon: const Icon(Icons.center_focus_strong_outlined, size: 16),
            label: const Text('Zoom to change'),
          ),
      ],
    );
  }

  Widget _body(BuildContext context, ui.Image left, ui.Image right) {
    final brightness = Theme.of(context).brightness;
    final palette = DiffPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lo = _origin(left), ro = _origin(right);
    final content = _viewport.contentSize;
    void hover(Offset? p) => setState(() => _hover = p);

    switch (_mode) {
      case ImageCompareMode.sideBySide:
        Widget pane(ui.Image image, Offset origin, String label,
                {required bool report}) =>
            Stack(
              children: [
                Positioned.fill(
                  child: ImageCanvas(
                    viewport: _viewport,
                    reportSize: report,
                    onHover: hover,
                    painter: _LayersPainter(
                      viewport: _viewport,
                      brightness: brightness,
                      content: content,
                      outline: scheme.outlineVariant,
                      layers: [_Layer(image, origin)],
                    ),
                  ),
                ),
                Positioned(top: 10, left: 10, child: _CornerLabel(text: label)),
              ],
            );
        return Row(
          children: [
            Expanded(child: pane(left, lo, widget.left.label, report: true)),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            Expanded(child: pane(right, ro, widget.right.label, report: false)),
          ],
        );
      case ImageCompareMode.swipe:
        return LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final split = _swipe * width;
          return Stack(
            children: [
              Positioned.fill(
                child: ImageCanvas(
                  viewport: _viewport,
                  onHover: hover,
                  painter: _LayersPainter(
                    viewport: _viewport,
                    brightness: brightness,
                    content: content,
                    outline: scheme.outlineVariant,
                    layers: [
                      _Layer(left, lo, clipRight: split),
                      _Layer(right, ro, clipLeft: split),
                    ],
                  ),
                ),
              ),
              Positioned(
                  top: 10,
                  left: 10,
                  child: _CornerLabel(text: widget.left.label)),
              Positioned(
                  top: 10,
                  right: 10,
                  child: _CornerLabel(text: widget.right.label)),
              Positioned(
                left: split - 16,
                top: 0,
                bottom: 0,
                width: 32,
                child: _SwipeHandle(
                  color: scheme.primary,
                  onDrag: (dx) => setState(
                      () => _swipe = ((split + dx) / width).clamp(0.0, 1.0)),
                ),
              ),
            ],
          );
        });
      case ImageCompareMode.onion:
        return ImageCanvas(
          viewport: _viewport,
          onHover: hover,
          painter: _LayersPainter(
            viewport: _viewport,
            brightness: brightness,
            content: content,
            outline: scheme.outlineVariant,
            layers: [
              _Layer(left, lo),
              _Layer(right, ro, opacity: _onion),
            ],
          ),
        );
      case ImageCompareMode.difference:
        final bounds = _analysis?.changedBounds(toleranceSteps(_tolerance));
        return Stack(
          children: [
            Positioned.fill(
              child: ImageCanvas(
                viewport: _viewport,
                onHover: hover,
                painter: _LayersPainter(
                  viewport: _viewport,
                  brightness: brightness,
                  content: content,
                  outline: scheme.outlineVariant,
                  layers: [
                    // The left image, faded to grey, as a backdrop that
                    // the changed pixels stand out from.
                    _Layer(left, lo, opacity: 0.35, greyscale: true),
                    if (_mask != null) _Layer(_mask!, Offset.zero, crisp: true),
                  ],
                  box: bounds == null
                      ? null
                      : Rect.fromLTRB(
                          bounds.left.toDouble(),
                          bounds.top.toDouble(),
                          bounds.right.toDouble(),
                          bounds.bottom.toDouble()),
                  boxColor: palette.removed,
                ),
              ),
            ),
            if (_analysis == null)
              const Center(child: CircularProgressIndicator()),
            if (_left?.rgba == null || _right?.rgba == null)
              const Center(
                child: Text('These images are too large to compare pixel by '
                    'pixel.'),
              ),
          ],
        );
    }
  }

  Widget _statusBar(BuildContext context, _ImageSide left, _ImageSide right) {
    final scheme = Theme.of(context).colorScheme;
    final style =
        monoStyle.copyWith(fontSize: 11.5, color: scheme.onSurfaceVariant);
    final hover = _hover;
    String text = 'Scroll to zoom · drag to pan · '
        '${AppAction.zoomReset.keyLabel} fits · point at a pixel to read it';
    if (hover != null) {
      final x = hover.dx.floor(), y = hover.dy.floor();
      String at(_ImageSide side) {
        final rgba = side.rgba;
        final image = side.image!;
        final o = _origin(image);
        final ix = x - o.dx.toInt(), iy = y - o.dy.toInt();
        if (rgba == null) return '—';
        if (ix < 0 || iy < 0 || ix >= rgba.width || iy >= rgba.height) {
          return 'outside';
        }
        final i = (iy * rgba.width + ix) * 4;
        final a = rgba.pixels[i + 3];
        // The buffer is premultiplied; show the colour as authored.
        int un(int c) => a == 0 ? 0 : (c * 255 / a).round().clamp(0, 255);
        String hex(int v) => v.toRadixString(16).padLeft(2, '0');
        return '#${hex(un(rgba.pixels[i]))}${hex(un(rgba.pixels[i + 1]))}'
            '${hex(un(rgba.pixels[i + 2]))}${hex(a)}';
      }

      final content = _viewport.contentSize;
      if (x >= 0 && y >= 0 && x < content.width && y < content.height) {
        text = 'x $x  y $y   left ${at(left)}   right ${at(right)}';
      }
    }
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Text(text,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
  }

  Widget _textFallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.notes, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Showing the files as text or binary.',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _textView = false),
                icon: const Icon(Icons.image_outlined, size: 17),
                label: const Text('Image view'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FileDiffView(
            left: widget.left,
            right: widget.right,
            title: widget.title,
            onBack: widget.onBack,
          ),
        ),
      ],
    );
  }

  static String _percent(double fraction) {
    final p = fraction * 100;
    if (p == 0) return '0 %';
    if (p < 0.01) return '< 0.01 %';
    return '${p < 10 ? p.toStringAsFixed(2) : p.toStringAsFixed(1)} %';
  }

  static String _count(int n) {
    final s = '$n';
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }
}

class _Layer {
  const _Layer(
    this.image,
    this.origin, {
    this.opacity = 1,
    this.greyscale = false,
    this.crisp = false,
    this.clipLeft,
    this.clipRight,
  });

  final ui.Image image;

  /// Top-left in canvas pixels.
  final Offset origin;
  final double opacity;
  final bool greyscale;

  /// Never smooth (for the difference mask, whose pixels must stay hard).
  final bool crisp;

  /// Screen-space clip, for the swipe divider.
  final double? clipLeft;
  final double? clipRight;
}

const _greyscale = ColorFilter.matrix([
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Paints images through the shared viewport over a checkerboard, with an
/// optional highlight box (the difference mode's bounding box).
class _LayersPainter extends CustomPainter {
  _LayersPainter({
    required this.viewport,
    required this.brightness,
    required this.content,
    required this.outline,
    required this.layers,
    this.box,
    this.boxColor,
  }) : super(repaint: viewport);

  final ImageViewport viewport;
  final Brightness brightness;
  final Size content;
  final Color outline;
  final List<_Layer> layers;
  final Rect? box;
  final Color? boxColor;

  @override
  void paint(Canvas canvas, Size size) {
    final view = Offset.zero & size;
    for (final layer in layers) {
      final image = layer.image;
      final rect = viewport.toScreen(Rect.fromLTWH(layer.origin.dx,
          layer.origin.dy, image.width.toDouble(), image.height.toDouble()));
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(
          layer.clipLeft ?? 0, 0, layer.clipRight ?? size.width, size.height));
      if (layer.opacity == 1 && !layer.crisp) {
        // Transparency shows the checkerboard; images faded on top of
        // another layer draw over that layer instead.
        Checkerboard.paint(canvas, rect.intersect(view), brightness);
      }
      final paint = Paint()
        ..color = Color.fromRGBO(0, 0, 0, layer.opacity)
        ..colorFilter = layer.greyscale ? _greyscale : null;
      if (layer.crisp) {
        paint.filterQuality = FilterQuality.none;
        canvas.drawImageRect(
            image,
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            rect,
            paint);
      } else {
        paintViewportImage(canvas, viewport, image, layer.origin, paint: paint);
      }
      canvas.restore();
    }
    // A hairline around the shared canvas, so image edges stay visible
    // against a background of the same colour.
    canvas.drawRect(
      viewport.toScreen(Offset.zero & content).inflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = outline,
    );
    final box = this.box;
    if (box != null && boxColor != null) {
      canvas.drawRect(
        viewport.toScreen(box).inflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = boxColor!,
      );
    }
  }

  @override
  bool shouldRepaint(_LayersPainter old) => true;
}

class _SwipeHandle extends StatelessWidget {
  const _SwipeHandle({required this.color, required this.onDrag});

  final Color color;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(width: 2, color: color),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(blurRadius: 6, color: Color(0x40000000)),
                ],
              ),
              child: Icon(Icons.code,
                  size: 16, color: Theme.of(context).colorScheme.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.viewport, required this.enabled});

  final ImageViewport viewport;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dense = TextButton.styleFrom(visualDensity: VisualDensity.compact);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Zoom out (${AppAction.zoomOut.keyLabel})',
          visualDensity: VisualDensity.compact,
          onPressed: enabled ? () => viewport.zoomCentered(0.8) : null,
          icon: const Icon(Icons.zoom_out, size: 19),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${(viewport.scale * 100).round()} %',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        IconButton(
          tooltip: 'Zoom in (${AppAction.zoomIn.keyLabel})',
          visualDensity: VisualDensity.compact,
          onPressed: enabled ? () => viewport.zoomCentered(1.25) : null,
          icon: const Icon(Icons.zoom_in, size: 19),
        ),
        const SizedBox(width: 4),
        TextButton(
          style: dense,
          onPressed: enabled ? viewport.fit : null,
          child: Text('Fit',
              style: TextStyle(
                  fontWeight:
                      viewport.isFitted ? FontWeight.w700 : FontWeight.w400)),
        ),
        TextButton(
          style: dense,
          onPressed: enabled ? viewport.actualSize : null,
          child: const Text('100 %'),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.left,
    required this.right,
    required this.leftName,
    required this.rightName,
  });

  final _ImageSide left;
  final _ImageSide right;
  final String leftName;
  final String rightName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget side(String name, _ImageSide s, TextAlign align) => Expanded(
          child: Tooltip(
            message: name,
            child: Text(
              s.describe(),
              textAlign: align,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          side(leftName, left, TextAlign.left),
          const SizedBox(width: 24),
          side(rightName, right, TextAlign.right),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }
}

class _CornerLabel extends StatelessWidget {
  const _CornerLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child:
            Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
      ),
    );
  }
}

/// Shown when a side is missing or cannot be decoded.
class _ProblemView extends StatelessWidget {
  const _ProblemView({
    required this.title,
    required this.leftSide,
    required this.rightSide,
    required this.left,
    required this.right,
    required this.onRetry,
    required this.onTextView,
    this.onBack,
  });

  final String title;
  final DiffSide leftSide;
  final DiffSide rightSide;
  final _ImageSide left;
  final _ImageSide right;
  final VoidCallback onRetry;
  final VoidCallback onTextView;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);

    Widget row(String role, DiffSide file, _ImageSide side) {
      final (icon, color, status) = side.ok
          ? (Icons.check_circle_outline, palette.added, side.describe())
          : side.missing
              ? (Icons.help_outline, palette.modified, 'Does not exist')
              : (Icons.broken_image_outlined, palette.removed, side.error!);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: file.description,
                    child: Text('$role  ·  ${file.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 2),
                  Text(status,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (side.ok)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 96,
                    height: 72,
                    child: RawImage(image: side.image, fit: BoxFit.contain),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final missing = left.missing || right.missing;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.image_not_supported_outlined,
                        color: scheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        missing
                            ? 'One of the images is missing'
                            : 'One of the images cannot be shown',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                row('Left', leftSide, left),
                row('Right', rightSide, right),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (onBack != null)
                        TextButton(
                            onPressed: onBack, child: const Text('Back')),
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Try again'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: onTextView,
                        icon: const Icon(Icons.notes, size: 18),
                        label: const Text('Compare as text / binary'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
