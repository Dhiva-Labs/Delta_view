import 'dart:io';

import 'package:delta_view/compare/diff_side.dart';
import 'package:delta_view/compare/sources/source_spec.dart';
import 'package:delta_view/ui/file_diff_view.dart';
import 'package:delta_view/ui/structured/structured_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
    }
  });
  await tester.pump();
}

Finder richText(String text) => find.textContaining(text, findRichText: true);

void main() {
  late Directory dir;
  String path(String name) => p.join(dir.path, name);

  setUp(() => dir = Directory.systemTemp.createTempSync('delta_view_struct'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, String left, String right) async {
    tester.view.physicalSize = const Size(2400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StructuredDiffView(
          left: DiffSide.source(LocalSource(path(left))),
          right: DiffSide.source(LocalSource(path(right))),
        ),
      ),
    ));
    await pumpUntil(tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
  }

  test('isStructuredFile', () {
    for (final name in ['a.json', 'b.YAML', 'c.yml', 'd.csv', 'e.TSV']) {
      expect(isStructuredFile(name), isTrue, reason: name);
    }
    for (final name in ['a.txt', 'json', 'b.jsonl', 'c.xml']) {
      expect(isStructuredFile(name), isFalse, reason: name);
    }
  });

  testWidgets('JSON tree: changes, paths, array matching by key',
      (tester) async {
    File(path('a.json')).writeAsStringSync(
        '{"server": {"port": 80}, "users": [{"id": 1, "n": "a"}, '
        '{"id": 2, "n": "b"}]}');
    File(path('b.json')).writeAsStringSync(
        '{"users": [{"id": 2, "n": "b"}, {"id": 1, "n": "A"}], '
        '"server": {"port": 8080}}');
    await open(tester, 'a.json', 'b.json');

    // By position, both users look changed.
    expect(find.text('port'), findsOneWidget);
    expect(richText('80  →  8080'), findsOneWidget);
    expect(find.text('~5'), findsOneWidget);

    await tester.tap(find.text('By key'));
    await pumpUntil(tester, () => find.text('~2').evaluate().isNotEmpty);
    expect(find.text('id: 1'), findsOneWidget);
    expect(find.text('moved from [0]'), findsOneWidget);

    // Keyboard navigation selects the first change and shows its path.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text(r'$.server.port'), findsOneWidget);
  });

  testWidgets('YAML and JSON compare as data', (tester) async {
    File(path('a.yaml')).writeAsStringSync('a: 1\nlist: [x, y]\n');
    File(path('b.json')).writeAsStringSync('{"list": ["x", "y"], "a": 1}');
    await open(tester, 'a.yaml', 'b.json');
    expect(find.text('identical values'), findsOneWidget);
    expect(find.text('Both documents hold the same data.'), findsOneWidget);
  });

  testWidgets('CSV rows match by key column', (tester) async {
    File(path('a.csv')).writeAsStringSync('id,city\n1,Paris\n2,Berlin\n');
    File(path('b.csv')).writeAsStringSync('id,city\n2,Bonn\n1,Paris\n3,Rome\n');
    await open(tester, 'a.csv', 'b.csv');
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('~1'), findsOneWidget);
    expect(richText('Berlin  →  Bonn'), findsOneWidget);
    // "Changes only" hides the unchanged Paris row until turned off.
    expect(find.text('Paris'), findsNothing);
    await tester.tap(find.text('Changes only'));
    await tester.pump();
    expect(find.text('Paris'), findsOneWidget);

    // Matching by city instead: Berlin left, Bonn and Rome arrived.
    await tester.tap(find.byTooltip('The column that identifies a row'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('city').last);
    await pumpUntil(tester, () => find.text('+2').evaluate().isNotEmpty);
    expect(find.text('−1'), findsOneWidget);
  });

  testWidgets('a parse error falls back to the text diff with a banner',
      (tester) async {
    File(path('a.json')).writeAsStringSync('{"a": 1}\n');
    File(path('b.json')).writeAsStringSync('{\n  "a": 1,\n  "b": [1,,]\n}\n');
    await open(tester, 'a.json', 'b.json');
    expect(find.byType(FileDiffView), findsOneWidget);
    expect(find.textContaining("Couldn't read b.json as JSON"), findsOneWidget);
    expect(find.textContaining('line 3, column'), findsOneWidget);

    await tester.tap(find.text('Structured'));
    await tester.pump();
    expect(find.text('No structured view for these files'), findsOneWidget);
  });
}
