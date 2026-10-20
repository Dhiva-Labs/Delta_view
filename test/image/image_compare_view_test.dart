import 'dart:io';
import 'dart:ui' as ui;

import 'package:delta_view/compare/diff_side.dart';
import 'package:delta_view/compare/sources/source_spec.dart';
import 'package:delta_view/ui/file_diff_view.dart';
import 'package:delta_view/ui/image/image_compare_view.dart';
import 'package:delta_view/ui/image/image_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// PNG bytes of a [size] × [size] image: [color] with a [spot] square.
Future<List<int>> pngOf(int size, Color color, {Color? spot}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = color);
  if (spot != null) {
    canvas.drawRect(const Rect.fromLTWH(2, 2, 3, 3), Paint()..color = spot);
  }
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 150 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
    }
  });
  await tester.pump();
}

void main() {
  late Directory dir;
  String path(String name) => p.join(dir.path, name);

  setUp(() => dir = Directory.systemTemp.createTempSync('delta_view_image'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, String left, String right) async {
    tester.view.physicalSize = const Size(2400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ImageCompareView(
          left: DiffSide.source(LocalSource(path(left))),
          right: DiffSide.source(LocalSource(path(right))),
        ),
      ),
    ));
  }

  testWidgets('shows the pixel difference and switches modes', (tester) async {
    await tester.runAsync(() async {
      File(path('a.png'))
          .writeAsBytesSync(await pngOf(10, const Color(0xFF3366CC)));
      File(path('b.png')).writeAsBytesSync(await pngOf(
          10, const Color(0xFF3366CC),
          spot: const Color(0xFFFFFFFF)));
    });
    await open(tester, 'a.png', 'b.png');
    await pumpUntil(tester,
        () => find.textContaining('of pixels differ').evaluate().isNotEmpty);
    // A 3×3 spot in a 10×10 image.
    expect(find.text('9.00 % of pixels differ'), findsOneWidget);
    expect(find.textContaining('PNG  ·  10 × 10'), findsNWidgets(2));

    for (final mode in ['Swipe', 'Onion skin', 'Difference']) {
      await tester.tap(find.text(mode));
      await pumpUntil(tester, () => true);
    }
    await pumpUntil(tester,
        () => find.textContaining('box 3 × 3 at 2, 2').evaluate().isNotEmpty);
    expect(find.textContaining('9 px (9.00 %)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers the text view when a side cannot be decoded',
      (tester) async {
    await tester.runAsync(() async {
      File(path('a.png'))
          .writeAsBytesSync(await pngOf(4, const Color(0xFF000000)));
    });
    File(path('b.png')).writeAsStringSync('not really a png');
    await open(tester, 'a.png', 'b.png');
    await pumpUntil(
        tester,
        () => find
            .text('One of the images cannot be shown')
            .evaluate()
            .isNotEmpty);
    expect(
        find.text('This is not an image this app can read.'), findsOneWidget);

    await tester.tap(find.text('Compare as text / binary'));
    await tester.pump();
    expect(find.byType(FileDiffView), findsOneWidget);
  });

  testWidgets('says when a side is missing', (tester) async {
    await tester.runAsync(() async {
      File(path('a.png'))
          .writeAsBytesSync(await pngOf(4, const Color(0xFF000000)));
    });
    await open(tester, 'a.png', 'gone.png');
    await pumpUntil(tester,
        () => find.text('One of the images is missing').evaluate().isNotEmpty);
    expect(find.text('Does not exist'), findsOneWidget);
  });

  test('viewport zooms around the focal point and fits', () {
    final v = ImageViewport()
      ..updateViewSize(const Size(424, 324))
      ..contentSize = const Size(800, 600);
    // Fit shrinks a large image to the view, minus a margin.
    expect(v.scale, closeTo(0.5, 1e-9));
    final focal = const Offset(100, 80);
    final under = v.toCanvas(focal);
    v.zoomAt(focal, 2);
    expect(v.scale, closeTo(1, 1e-9));
    expect(v.toCanvas(focal).dx, closeTo(under.dx, 1e-9));
    expect(v.toCanvas(focal).dy, closeTo(under.dy, 1e-9));
    v.actualSize();
    expect(v.scale, 1);
    v.fit();
    expect(v.scale, closeTo(0.5, 1e-9));
    // A small image opens at 100 %, but Fit may enlarge it.
    v.contentSize = const Size(100, 100);
    expect(v.scale, 1);
    v.fit();
    expect(v.scale, closeTo(3, 1e-9));
  });
}
