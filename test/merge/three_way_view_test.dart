import 'dart:io';

import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/ui/merge/three_way_view.dart';
import 'package:delta_view/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pumps (with real time passing, for file IO) until [done] holds.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
    }
  });
  await tester.pump();
}

Future<void> pressWith(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  late Directory dir;
  String path(String name) => p.join(dir.path, name);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('delta_view_merge');
    // Left and right change line 2 differently (a conflict); right also
    // appends a line (clean). CRLF in the base must survive the save.
    File(path('base.txt')).writeAsStringSync('one\r\ntwo\r\nthree\r\n');
    File(path('left.txt')).writeAsStringSync('one\nTWO\nthree\n');
    File(path('right.txt')).writeAsStringSync('one\n2\nthree\nfour\n');
    File(path('out.txt')).writeAsStringSync('git wrote markers here\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ThreeWayComparison comparison({bool output = true}) => ThreeWayComparison(
        left: LocalSource(path('left.txt')),
        base: LocalSource(path('base.txt')),
        right: LocalSource(path('right.txt')),
        output: output ? LocalSource(path('out.txt')) : null,
      );

  Future<void> open(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(2400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: child));
    await pumpUntil(
      tester,
      () => find.textContaining('conflict').evaluate().isNotEmpty,
    );
  }

  testWidgets('resolves from the keyboard and saves to the output', (
    tester,
  ) async {
    await open(
      tester,
      Scaffold(body: ThreeWayMergeView(comparison: comparison())),
    );

    expect(find.text('1 conflict left'), findsOneWidget);
    expect(find.text('1 change merged automatically'), findsOneWidget);

    // The first conflict is selected on open: Alt+← takes the right side.
    await pressWith(
      tester,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.arrowLeft,
    );
    expect(find.text('All conflicts resolved'), findsOneWidget);

    // Undo brings the conflict back; redo resolves it again.
    await pressWith(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyZ,
    );
    expect(find.text('1 conflict left'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('All conflicts resolved'), findsOneWidget);

    await pressWith(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyS,
    );
    await pumpUntil(
      tester,
      () => File(path('out.txt')).readAsStringSync().startsWith('one'),
    );
    expect(
      File(path('out.txt')).readAsStringSync(),
      'one\r\n2\r\nthree\r\nfour\r\n',
    );
    await pumpUntil(tester, () => find.text('● unsaved').evaluate().isEmpty);
    expect(find.text('● unsaved'), findsNothing);
  });

  testWidgets('warns before saving with conflicts and writes markers', (
    tester,
  ) async {
    await open(
      tester,
      Scaffold(body: ThreeWayMergeView(comparison: comparison())),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('1 conflict is not resolved'), findsOneWidget);
    await tester.tap(find.text('Save with markers'));
    await pumpUntil(
      tester,
      () => File(path('out.txt')).readAsStringSync().startsWith('one'),
    );
    expect(
      File(path('out.txt')).readAsStringSync(),
      'one\r\n<<<<<<< left.txt\r\nTWO\r\n||||||| base.txt\r\ntwo\r\n'
      '=======\r\n2\r\n>>>>>>> right.txt\r\nthree\r\nfour\r\n',
    );
  });

  testWidgets('asks where to save when there is no output', (tester) async {
    await open(
      tester,
      Scaffold(body: ThreeWayMergeView(comparison: comparison(output: false))),
    );

    // Take left for the conflict with the gutter arrow, then save.
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded).first);
    await tester.pump();
    expect(find.text('All conflicts resolved'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save…'));
    await pumpUntil(
      tester,
      () => find.text('Where should the merge go?').evaluate().isNotEmpty,
    );
    await tester.tap(find.textContaining('Overwrite base'));
    await pumpUntil(
      tester,
      () => File(path('base.txt')).readAsStringSync().contains('TWO'),
    );
    expect(
      File(path('base.txt')).readAsStringSync(),
      'one\r\nTWO\r\nthree\r\nfour\r\n',
    );
    // Later saves go to the same place without asking.
    await pumpUntil(tester,
        () => find.widgetWithText(FilledButton, 'Save').evaluate().isNotEmpty);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
  });

  testWidgets('edits a chunk by hand inline', (tester) async {
    await open(
      tester,
      Scaffold(body: ThreeWayMergeView(comparison: comparison())),
    );

    await pressWith(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyE,
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    // An unresolved conflict starts as conflict markers.
    expect(
      tester.widget<TextField>(field).controller!.text,
      startsWith('<<<<<<< left.txt'),
    );
    await tester.enterText(field, 'Two, merged');
    await pressWith(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.enter,
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('All conflicts resolved'), findsOneWidget);
    expect(find.text('Two, merged'), findsOneWidget);
  });

  testWidgets('double-click edits, and Cancel throws the edit away',
      (tester) async {
    await open(tester,
        Scaffold(body: ThreeWayMergeView(comparison: comparison())));

    // The unresolved conflict shows the base line as a placeholder.
    final placeholder = find.text('two');
    await tester.tap(placeholder.first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(placeholder.first);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'typed');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('typed'), findsNothing);
    expect(find.text('1 conflict left'), findsOneWidget);
  });

  testWidgets('guards closing the tab while unsaved', (tester) async {
    await open(tester, TabbedShell(initialComparisons: [comparison()]));
    final shell = tester.state<TabbedShellState>(find.byType(TabbedShell));
    expect(shell.tabs.single.dirty, isTrue);

    final closing = shell.closeTab(shell.tabs.single.id);
    await tester.pumpAndSettle();
    expect(find.text('Save the merge?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await closing, isFalse);
    expect(find.byType(ThreeWayMergeView), findsOneWidget);

    final closingAgain = shell.closeTab(shell.tabs.single.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close without saving'));
    await tester.pumpAndSettle();
    expect(await closingAgain, isTrue);
    expect(find.byType(ThreeWayMergeView), findsNothing);
  });

  testWidgets('a missing base merges as if empty', (tester) async {
    File(path('base.txt')).deleteSync();
    await open(
      tester,
      Scaffold(body: ThreeWayMergeView(comparison: comparison())),
    );
    expect(find.textContaining('There is no base file'), findsOneWidget);
    expect(find.text('1 conflict left'), findsOneWidget);
  });
}
