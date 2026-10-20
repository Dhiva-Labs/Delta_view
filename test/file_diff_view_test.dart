import 'dart:io';

import 'package:delta_view/compare/diff_side.dart';
import 'package:delta_view/compare/sources/source_spec.dart';
import 'package:delta_view/ui/file_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('loads real files and shows the diff without errors',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('delta_view_widget');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('one\ntwo\nthree\n');
    File(p.join(dir.path, 'b.txt')).writeAsStringSync('one\nTWO\nthree\nfour\n');

    // Real async work (file IO + Isolate.run) needs runAsync — this is the
    // path that regressed when the isolate closure captured the State.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FileDiffView(
            left: DiffSide.source(LocalSource(p.join(dir.path, 'a.txt'))),
            right: DiffSide.source(LocalSource(p.join(dir.path, 'b.txt'))),
          ),
        ),
      ));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (tester
            .widgetList(find.byType(CircularProgressIndicator))
            .isEmpty) {
          break;
        }
      }
    });

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not read files'), findsNothing);
    // One modified line (~1) and one added line (+1).
    expect(find.text('~1'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
  });
}
