import 'dart:typed_data';

import 'package:delta_view/ui/image/image_diff.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [width] × [height] image filled with one premultiplied RGBA colour.
RgbaImage solid(int width, int height, List<int> rgba) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    pixels.setRange(i * 4, i * 4 + 4, rgba);
  }
  return RgbaImage(width, height, pixels);
}

void setPixel(RgbaImage image, int x, int y, List<int> rgba) {
  final i = (y * image.width + x) * 4;
  image.pixels.setRange(i, i + 4, rgba);
}

void main() {
  const grey = [100, 100, 100, 255];

  group('analyzeImageDiff', () {
    test('identical images have no changes', () {
      final a = analyzeImageDiff(solid(4, 3, grey), solid(4, 3, grey));
      expect(a.width, 4);
      expect(a.height, 3);
      expect(a.changedPixels(0), 0);
      expect(a.changedFraction(0), 0);
      expect(a.changedBounds(0), isNull);
    });

    test('counts changed pixels and boxes them', () {
      final left = solid(10, 8, grey);
      final right = solid(10, 8, grey);
      setPixel(right, 2, 3, [110, 100, 100, 255]); // delta 10
      setPixel(right, 7, 5, [100, 100, 160, 255]); // delta 60
      final a = analyzeImageDiff(left, right);
      expect(a.changedPixels(0), 2);
      expect(a.changedFraction(0), 2 / 80);
      expect(a.changedBounds(0), const PixelBounds(2, 3, 8, 6));
      expect(a.delta[3 * 10 + 2], 10);
      expect(a.delta[5 * 10 + 7], 60);
    });

    test('tolerance ignores small differences, instantly', () {
      final left = solid(10, 8, grey);
      final right = solid(10, 8, grey);
      setPixel(right, 2, 3, [110, 100, 100, 255]); // delta 10
      setPixel(right, 7, 5, [100, 100, 160, 255]); // delta 60
      final a = analyzeImageDiff(left, right);
      expect(a.changedPixels(9), 2);
      expect(a.changedPixels(10), 1, reason: 'delta must exceed tolerance');
      expect(a.changedBounds(10), const PixelBounds(7, 5, 8, 6));
      expect(a.changedPixels(60), 0);
      expect(a.changedBounds(60), isNull);
    });

    test('alpha changes count, invisible colour under alpha 0 does not', () {
      // Premultiplied: fully transparent pixels are all zero whatever
      // colour they were authored with.
      final left = solid(2, 1, [0, 0, 0, 0]);
      final right = solid(2, 1, [0, 0, 0, 0]);
      setPixel(right, 1, 0, [0, 0, 0, 40]);
      final a = analyzeImageDiff(left, right);
      expect(a.changedPixels(0), 1);
      expect(a.delta[1], 40);
    });

    test('different sizes, aligned top-left', () {
      final a = analyzeImageDiff(solid(4, 4, grey), solid(2, 2, grey));
      expect((a.width, a.height), (4, 4));
      // The 2×2 overlap matches; the other 12 pixels exist on one side.
      expect(a.changedPixels(0), 12);
      expect(a.changedPixels(254), 12, reason: 'one-sided pixels always count');
      expect(a.changedBounds(0), const PixelBounds(0, 0, 4, 4));
      expect(a.delta[0], 0);
      expect(a.delta[3], 255);
    });

    test('different sizes, aligned centre', () {
      final a = analyzeImageDiff(solid(4, 4, grey), solid(2, 2, grey),
          alignment: ImageAlignment.center);
      expect(a.changedPixels(0), 12);
      // The centre 2×2 matches now.
      expect(a.delta[1 * 4 + 1], 0);
      expect(a.delta[2 * 4 + 2], 0);
      expect(a.delta[0], 255);
    });

    test('canvas areas outside both images are not changes', () {
      // 4×1 and 1×4 share only the corner; the rest of the 4×4 canvas is
      // covered by one or neither.
      final a = analyzeImageDiff(solid(4, 1, grey), solid(1, 4, grey));
      expect(a.changedPixels(0), 6);
      expect(a.delta[3 * 4 + 3], 0);
    });
  });

  test('alignedOrigin', () {
    expect(alignedOrigin(2, 2, 4, 4, ImageAlignment.topLeft), (0, 0));
    expect(alignedOrigin(2, 2, 5, 4, ImageAlignment.center), (1, 1));
    expect(alignedOrigin(4, 4, 4, 4, ImageAlignment.center), (0, 0));
  });

  test('renderDiffMask paints changed pixels only', () {
    final left = solid(3, 1, grey);
    final right = solid(3, 1, grey);
    setPixel(right, 1, 0, [200, 100, 100, 255]);
    final mask =
        renderDiffMask(analyzeImageDiff(left, right), 0, color: 0xFF112233);
    expect(mask.sublist(0, 4), [0, 0, 0, 0]);
    expect(mask.sublist(4, 8), [0x11, 0x22, 0x33, 255]);
    expect(mask.sublist(8, 12), [0, 0, 0, 0]);
    expect(renderDiffMask(analyzeImageDiff(left, right), 100), everyElement(0));
  });

  test('toleranceSteps maps percent to channel steps', () {
    expect(toleranceSteps(0), 0);
    expect(toleranceSteps(50), 127);
    expect(toleranceSteps(100), 254);
    expect(toleranceSteps(150), 254);
  });

  test('a large image analyses quickly', () {
    final left = solid(2000, 1500, grey);
    final right = solid(2000, 1500, grey);
    setPixel(right, 1999, 1499, [0, 0, 0, 255]);
    final sw = Stopwatch()..start();
    final a = analyzeImageDiff(left, right);
    expect(sw.elapsedMilliseconds, lessThan(5000));
    expect(a.changedBounds(0), const PixelBounds(1999, 1499, 2000, 1500));
  });
}
