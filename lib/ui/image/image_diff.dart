/// Pixel comparison of two decoded images. Pure Dart over RGBA byte
/// buffers, so it runs in an isolate and is tested without a GPU.
///
/// One pass measures how much every pixel changed. Everything that depends
/// on the tolerance (changed count, bounding box) is then answered from a
/// 256-bin summary of that pass, so dragging the tolerance slider is
/// instant; only the highlight mask needs another pass over the pixels.
library;

import 'dart:typed_data';

/// Where a smaller image sits in the canvas both images share.
enum ImageAlignment { topLeft, center }

/// The top-left corner of a [width] × [height] image inside a
/// [canvasWidth] × [canvasHeight] canvas.
(int, int) alignedOrigin(int width, int height, int canvasWidth,
        int canvasHeight, ImageAlignment alignment) =>
    alignment == ImageAlignment.topLeft
        ? (0, 0)
        : ((canvasWidth - width) ~/ 2, (canvasHeight - height) ~/ 2);

/// A rectangle of pixels, in canvas coordinates.
class PixelBounds {
  const PixelBounds(this.left, this.top, this.right, this.bottom);

  /// Inclusive.
  final int left, top;

  /// Exclusive.
  final int right, bottom;

  int get width => right - left;
  int get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      other is PixelBounds &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PixelBounds($left, $top, $right, $bottom)';
}

/// An RGBA image: 4 bytes per pixel, row by row, premultiplied alpha (as
/// `ImageByteFormat.rawRgba` gives it). Premultiplied matters: every fully
/// transparent pixel is all zeros, so invisible colour differences under
/// alpha 0 never count as changes.
class RgbaImage {
  const RgbaImage(this.width, this.height, this.pixels)
      : assert(pixels.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;
}

class ImageDiffAnalysis {
  ImageDiffAnalysis._(
      this.width, this.height, this.delta, this.histogram, this._boundsByDelta);

  /// The shared canvas: as wide and as tall as the larger image.
  final int width;
  final int height;

  /// How much each canvas pixel changed: the largest difference of any
  /// channel, 0–255. A pixel only one image covers counts as 255.
  final Uint8List delta;

  /// How many pixels changed by exactly each amount.
  final Int64List histogram;

  /// For each delta value, the box around the pixels with that delta, as
  /// left, top, right, bottom (exclusive); -1s when there are none.
  final Int32List _boundsByDelta;

  int get pixelCount => width * height;

  /// Pixels whose change is greater than [tolerance] (0–255).
  int changedPixels(int tolerance) {
    var count = 0;
    for (var d = tolerance + 1; d < 256; d++) {
      count += histogram[d];
    }
    return count;
  }

  double changedFraction(int tolerance) =>
      pixelCount == 0 ? 0 : changedPixels(tolerance) / pixelCount;

  /// The smallest box holding every pixel that changed by more than
  /// [tolerance], or null when none did.
  PixelBounds? changedBounds(int tolerance) {
    int? left, top, right, bottom;
    for (var d = tolerance + 1; d < 256; d++) {
      final i = d * 4;
      if (_boundsByDelta[i] < 0) continue;
      left =
          left == null || _boundsByDelta[i] < left ? _boundsByDelta[i] : left;
      top = top == null || _boundsByDelta[i + 1] < top
          ? _boundsByDelta[i + 1]
          : top;
      right = right == null || _boundsByDelta[i + 2] > right
          ? _boundsByDelta[i + 2]
          : right;
      bottom = bottom == null || _boundsByDelta[i + 3] > bottom
          ? _boundsByDelta[i + 3]
          : bottom;
    }
    return left == null ? null : PixelBounds(left, top!, right!, bottom!);
  }
}

/// Measures how every pixel of [left] and [right] differs, with the smaller
/// image placed by [alignment] in a canvas the size of both.
ImageDiffAnalysis analyzeImageDiff(
  RgbaImage left,
  RgbaImage right, {
  ImageAlignment alignment = ImageAlignment.topLeft,
}) {
  final width = left.width > right.width ? left.width : right.width;
  final height = left.height > right.height ? left.height : right.height;
  final (lx, ly) =
      alignedOrigin(left.width, left.height, width, height, alignment);
  final (rx, ry) =
      alignedOrigin(right.width, right.height, width, height, alignment);

  final delta = Uint8List(width * height);
  final histogram = Int64List(256);
  final bounds = Int32List(256 * 4)..fillRange(0, 256 * 4, -1);
  final lp = left.pixels, rp = right.pixels;

  for (var y = 0; y < height; y++) {
    final lyy = y - ly, ryy = y - ry;
    final inLeftRow = lyy >= 0 && lyy < left.height;
    final inRightRow = ryy >= 0 && ryy < right.height;
    for (var x = 0; x < width; x++) {
      final lxx = x - lx, rxx = x - rx;
      final inLeft = inLeftRow && lxx >= 0 && lxx < left.width;
      final inRight = inRightRow && rxx >= 0 && rxx < right.width;
      int d;
      if (inLeft && inRight) {
        final li = (lyy * left.width + lxx) * 4;
        final ri = (ryy * right.width + rxx) * 4;
        d = 0;
        for (var c = 0; c < 4; c++) {
          final diff = lp[li + c] - rp[ri + c];
          final abs = diff < 0 ? -diff : diff;
          if (abs > d) d = abs;
        }
      } else if (inLeft || inRight) {
        d = 255;
      } else {
        d = 0; // Outside both images: nothing to compare.
      }
      delta[y * width + x] = d;
      histogram[d]++;
      if (d > 0) {
        final b = d * 4;
        if (bounds[b] < 0) {
          bounds[b] = x;
          bounds[b + 1] = y;
          bounds[b + 2] = x + 1;
          bounds[b + 3] = y + 1;
        } else {
          if (x < bounds[b]) bounds[b] = x;
          if (x + 1 > bounds[b + 2]) bounds[b + 2] = x + 1;
          // Rows are visited in order, so the top never moves up.
          bounds[b + 3] = y + 1;
        }
      }
    }
  }
  return ImageDiffAnalysis._(width, height, delta, histogram, bounds);
}

/// An RGBA mask the size of the canvas: [color] (0xAARRGGBB, opaque) where
/// a pixel changed by more than [tolerance], transparent elsewhere. Alpha
/// is 0 or 255 only, so the bytes read the same premultiplied or not.
Uint8List renderDiffMask(ImageDiffAnalysis analysis, int tolerance,
    {int color = 0xFFFF2D95}) {
  final out = Uint8List(analysis.pixelCount * 4);
  final r = (color >> 16) & 0xFF, g = (color >> 8) & 0xFF, b = color & 0xFF;
  final delta = analysis.delta;
  for (var i = 0; i < delta.length; i++) {
    if (delta[i] > tolerance) {
      final o = i * 4;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
      out[o + 3] = 255;
    }
  }
  return out;
}

/// The tolerance slider works in percent; the analysis in channel steps.
/// 100 % still keeps pixels only one image has (delta 255) as changes.
int toleranceSteps(double percent) =>
    (percent.clamp(0, 100) / 100 * 254).round();
