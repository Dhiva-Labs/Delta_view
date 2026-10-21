import 'dart:io';

import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/compare/diff_side.dart';
import 'package:delta_view/diff/text_codec.dart';
import 'package:delta_view/settings/app_settings.dart';
import 'package:delta_view/ui/file_diff_view.dart';
import 'package:delta_view/ui/shell.dart';
import 'package:delta_view/ui/shortcuts/app_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Writes two files into a fresh temp folder.
(String, String) _files(Object left, Object right) {
  final dir = Directory.systemTemp.createTempSync('delta_view_widget');
  addTearDown(() => dir.deleteSync(recursive: true));
  final a = p.join(dir.path, 'a.txt'), b = p.join(dir.path, 'b.txt');
  for (final (path, content) in [(a, left), (b, right)]) {
    if (content is String) {
      File(path).writeAsStringSync(content);
    } else {
      File(path).writeAsBytesSync(content as List<int>);
    }
  }
  return (a, b);
}

/// Lets real file IO, isolates and debounce timers run until [done].
Future<void> _settle(WidgetTester tester, {bool Function()? done}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
      final loading =
          tester.widgetList(find.byType(CircularProgressIndicator)).isNotEmpty;
      if (!loading && (done == null || done())) break;
    }
  });
  await tester.pump(const Duration(milliseconds: 300));
}

bool _shows(String text) => find.text(text).evaluate().isNotEmpty;

Future<void> _pumpDiff(WidgetTester tester, String a, String b) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDiffView(
          left: DiffSide.source(LocalSource(a)),
          right: DiffSide.source(LocalSource(b)),
        ),
      ),
    ));
  });
  await _settle(tester);
}

Future<void> _keys(WidgetTester tester, LogicalKeyboardKey key,
    {bool control = false, bool alt = false}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  tearDown(() {
    appSettings
      ..foldUnchanged = false
      ..wordWrap = false;
  });

  testWidgets('loads real files and shows the diff without errors',
      (tester) async {
    final (a, b) = _files('one\ntwo\nthree\n', 'one\nTWO\nthree\nfour\n');
    // Real async work (file IO + Isolate.run) needs runAsync — this is the
    // path that regressed when the isolate closure captured the State.
    await _pumpDiff(tester, a, b);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not read files'), findsNothing);
    // One modified line (~1) and one added line (+1).
    expect(find.text('~1'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    // Shape as well as colour: gutter markers next to the line numbers.
    expect(find.text('~'), findsNWidgets(2));
    expect(find.text('+'), findsOneWidget);
  });

  testWidgets('copies a change across, saves it, and undo takes it back',
      (tester) async {
    final (a, b) = _files('one\ntwo\nthree\n', 'one\nTWO\nthree\n');
    await _pumpDiff(tester, a, b);
    expect(find.text('~1'), findsOneWidget);

    // The gutter arrow copies the left version over the right one, without
    // switching to edit mode.
    await tester.tap(find.byIcon(Icons.arrow_forward).first);
    await _settle(tester, done: () => _shows('identical'));
    expect(find.text('identical'), findsOneWidget);
    expect(find.text('● unsaved'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);

    await _keys(tester, LogicalKeyboardKey.keyZ, control: true);
    await _settle(tester, done: () => _shows('~1'));
    expect(find.text('~1'), findsOneWidget);
    expect(find.text('● unsaved'), findsNothing);

    await _keys(tester, LogicalKeyboardKey.keyZ, control: true);
    // Nothing more to undo; redo brings the copy back.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester, done: () => _shows('identical'));
    expect(find.text('identical'), findsOneWidget);

    await _keys(tester, LogicalKeyboardKey.keyS, control: true);
    await _settle(tester, done: () => !_shows('● unsaved'));
    expect(File(b).readAsStringSync(), 'one\ntwo\nthree\n');
    expect(find.text('● unsaved'), findsNothing);
  });

  testWidgets('saving keeps the encoding, byte order mark and line endings',
      (tester) async {
    List<int> utf16le(String s) => [
          0xFF,
          0xFE,
          for (final u in s.codeUnits) ...[u & 0xFF, u >> 8],
        ];
    final (a, b) = _files(utf16le('alpha\r\nbeta\r\n'), 'alpha\nBETA\n');
    await _pumpDiff(tester, a, b);
    expect(find.text('UTF-16 LE'), findsOneWidget);
    expect(find.text('CRLF'), findsOneWidget);

    // Right → left, then save: still UTF-16 LE with BOM and CRLF.
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await _settle(tester, done: () => _shows('identical'));
    await _keys(tester, LogicalKeyboardKey.keyS, control: true);
    await _settle(tester, done: () => !_shows('● unsaved'));
    final saved = decodeText(File(a).readAsBytesSync());
    expect(saved.format.encoding, TextEncoding.utf16le);
    expect(saved.format.bom, isTrue);
    expect(saved.format.lineEnding, LineEnding.crlf);
    expect(saved.text, 'alpha\nBETA\n');
  });

  testWidgets('undo in an editor goes through the shared history',
      (tester) async {
    final (a, b) = _files('one\ntwo\n', 'one\ntwo\n');
    await _pumpDiff(tester, a, b);
    await _keys(tester, LogicalKeyboardKey.keyE, control: true);
    await _settle(tester);
    final left = find.byType(EditableText).first;
    await tester.tap(left);
    await tester.enterText(left, 'one\nTWO\n');
    await _settle(tester, done: () => _shows('~1'));
    expect(find.text('~1'), findsOneWidget);

    // Ctrl+Z inside the focused editor reaches the comparison's history
    // (not only the text field's own), so redo knows about it.
    await _keys(tester, LogicalKeyboardKey.keyZ, control: true);
    await _settle(tester, done: () => _shows('identical'));
    expect(find.text('identical'), findsOneWidget);
    expect(find.byTooltip('Redo typing (${AppAction.redo.keyLabel})'),
        findsOneWidget);
  });

  testWidgets('finds across both sides with a match count', (tester) async {
    final (a, b) = _files('apple\nbanana\n', 'apple pie\ncherry\n');
    await _pumpDiff(tester, a, b);
    await _keys(tester, LogicalKeyboardKey.keyF, control: true);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '').last, 'apple');
    await tester.pump();
    expect(find.text('1 of 2'), findsOneWidget);
    await _keys(tester, LogicalKeyboardKey.f3);
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'APPLE');
    await tester.pump();
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Match case'));
    await tester.pump();
    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('folds unchanged runs and opens one on click', (tester) async {
    final lines = [for (var i = 0; i < 40; i++) 'line $i'];
    final changed = List.of(lines)..[20] = 'CHANGED';
    final (a, b) = _files('${lines.join('\n')}\n', '${changed.join('\n')}\n');
    appSettings.foldUnchanged = true;
    await _pumpDiff(tester, a, b);
    // 20 unchanged lines above the change keep 3 of context, as do the 19
    // below it.
    // The marker spans both panes.
    expect(find.text('17 unchanged lines'), findsNWidgets(2));
    expect(find.text('16 unchanged lines'), findsNWidgets(2));
    final line0 = find.text('line 0', findRichText: true);
    expect(line0, findsNothing);
    expect(find.text('line 18', findRichText: true), findsNWidgets(2));
    await tester.tap(find.text('17 unchanged lines').first);
    await tester.pump();
    expect(line0, findsNWidgets(2));
    // Alt+U shows everything again.
    await _keys(tester, LogicalKeyboardKey.keyU, alt: true);
    await tester.pump();
    expect(find.textContaining('unchanged lines'), findsNothing);
  });

  testWidgets('honours the compare rules picked in the toolbar',
      (tester) async {
    final (a, b) = _files('Hello  world\n', 'hello world\n');
    await _pumpDiff(tester, a, b);
    expect(find.text('~1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore case'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore changes in whitespace'));
    await tester.pumpAndSettle();
    await _settle(tester, done: () => _shows('identical'));
    expect(find.text('identical'), findsOneWidget);
    expect(find.textContaining('Ignoring whitespace changes, case'),
        findsOneWidget);
  });

  testWidgets('asks before closing a tab with unsaved changes', (tester) async {
    final (a, b) = _files('one\ntwo\n', 'one\nTWO\n');
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: TabbedShell(initialComparisons: [
          FileComparison(LocalSource(a), LocalSource(b)),
        ]),
      ));
    });
    await _settle(tester);
    final shell = tester.state<TabbedShellState>(find.byType(TabbedShell));
    final tab = shell.tabs.single;

    await tester.tap(find.byIcon(Icons.arrow_forward).first);
    await _settle(tester, done: () => shell.tabs.single.dirty);
    expect(shell.tabs.single.dirty, isTrue);
    expect(shell.tabs.single.closeGuard, isNotNull);

    var closing = shell.closeTab(tab.id);
    await tester.pumpAndSettle();
    expect(find.text('Save changes to b.txt?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await closing, isFalse);
    expect(shell.tabs.single.id, tab.id);

    closing = shell.closeTab(tab.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't save"));
    await tester.pumpAndSettle();
    expect(await closing, isTrue);
    expect(shell.tabs.single.id, isNot(tab.id));
    expect(File(b).readAsStringSync(), 'one\nTWO\n');
  });

  testWidgets('reloads a file that changed on disk, or offers to',
      (tester) async {
    final (a, b) = _files('one\ntwo\n', 'one\ntwo\n');
    await _pumpDiff(tester, a, b);
    expect(find.text('identical'), findsOneWidget);

    // No unsaved edits: reload straight away.
    await tester.runAsync(() async {
      // Let the folder watch start before changing the file.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      File(b).writeAsStringSync('one\nTWO\n');
    });
    await _settle(tester, done: () => _shows('~1'));
    expect(find.text('~1'), findsOneWidget);
    expect(find.text('Reloaded b.txt: it changed on disk'), findsOneWidget);

    // Unsaved edits on the left: offer instead.
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await _settle(tester, done: () => _shows('identical'));
    await tester.runAsync(() async {
      File(a).writeAsStringSync('one\nthree\n');
    });
    await _settle(tester, done: () => _shows('a.txt changed on disk.'));
    expect(find.text('a.txt changed on disk.'), findsOneWidget);
    await tester.tap(find.text('Keep mine'));
    await tester.pump();
    expect(find.text('a.txt changed on disk.'), findsNothing);
    expect(find.text('identical'), findsOneWidget);
  });

  testWidgets('pasted text sides take a Paste button and save as a file',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': 'pasted\r\ntext\r\n'};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FileDiffView(
            left: DiffSide.memory(text: 'pasted\ntext\n', label: 'Left text'),
            right: DiffSide.memory(text: '', label: 'Right text'),
          ),
        ),
      ));
    });
    await _settle(tester);
    expect(find.text('Paste'), findsNWidgets(2));
    expect(find.text('Save as…'), findsNWidgets(2));
    await tester.tap(find.text('Paste').last);
    await _settle(tester, done: () => _shows('identical'));
    expect(find.text('identical'), findsOneWidget);
    // The pasted CRLF text keeps CRLF for when it is saved.
    expect(find.text('CRLF'), findsOneWidget);
  });
}
