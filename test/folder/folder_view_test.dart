import 'dart:io';

import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/settings/app_settings.dart';
import 'package:delta_view/ui/folder/tree_model.dart';
import 'package:delta_view/ui/folder/tree_rows.dart';
import 'package:delta_view/ui/folder_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String left, right;

  setUp(() {
    root = Directory.systemTemp.createTempSync('delta_view_view');
    left = p.join(root.path, 'left');
    right = p.join(root.path, 'right');
    void file(String side, String path, String text) =>
        File(p.join(side, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
    file(left, 'a.txt', 'same');
    file(right, 'a.txt', 'same');
    file(left, 'b.txt', 'left');
    file(right, 'b.txt', 'right!');
    file(left, 'only-left.txt', 'x');
    file(right, 'dir/only-right.txt', 'y');
    file(left, 'node_modules/pkg.js', 'ignored');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> pumpView(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FolderDiffView(
            left: LocalSource(left), right: LocalSource(right)),
      ),
    ));
    expect(find.text('Scanning folders…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    // The scan runs in a real isolate: give it real time.
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (find.text('Synchronize…').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('shows the changes with a status icon and the ignored count',
      (tester) async {
    await pumpView(tester);
    expect(find.text('b.txt'), findsNWidgets(2));
    expect(find.text('only-left.txt'), findsOneWidget);
    expect(find.text('dir'), findsOneWidget);
    // Identical files are hidden by the default "Changes" filter.
    expect(appSettings.defaultFolderFilter, FolderFilterDefault.changes);
    expect(find.text('a.txt'), findsNothing);
    expect(find.text('1 ignored'), findsOneWidget);
    expect(find.byTooltip('Modified'), findsWidgets);
    expect(find.byTooltip('Left only'), findsWidgets);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsNWidgets(2));
  });

  testWidgets('arrow keys move the selection, space toggles it',
      (tester) async {
    await pumpView(tester);
    await tester.tap(find.text('b.txt').first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    String? cursor() => tester
        .widgetList<FolderTreeRow>(find.byType(FolderTreeRow))
        .where((row) => row.cursor)
        .firstOrNull
        ?.node
        .relativePath;
    expect(cursor(), 'only-left.txt');
    int selected() => tester
        .widgetList<FolderTreeRow>(find.byType(FolderTreeRow))
        .where((row) => row.selected)
        .length;
    expect(selected(), 1);

    // Up twice reaches the file inside the folder opened on arrival.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(cursor(), 'dir/only-right.txt');
    // Left jumps to the parent folder, then closes it; Right opens it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(cursor(), 'dir');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('only-right.txt'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('only-right.txt'), findsOneWidget);

    // Shift extends the selection; Space takes the cursor row out of it.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selected(), 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(selected(), 2);
  });

  testWidgets('sorts by size with folders first', (tester) async {
    await pumpView(tester);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size').first); // descending
    await tester.pumpAndSettle();
    final names = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ListView), matching: find.byType(Text)))
        .map((t) => t.data)
        .where((n) => n != null && (n.endsWith('.txt') || n == 'dir'))
        .toList();
    expect(names.first, 'dir');
    // b.txt is the largest file on the left (4 bytes vs 'same' 4, 'x' 1).
    expect(names.indexOf('only-left.txt'), greaterThan(names.indexOf('b.txt')));
  });

  test('tree filters come from settings', () {
    expect(TreeFilter.fromSetting(FolderFilterDefault.all), TreeFilter.all);
    expect(TreeFilter.fromSetting(FolderFilterDefault.rightOnly),
        TreeFilter.rightOnly);
  });
}
