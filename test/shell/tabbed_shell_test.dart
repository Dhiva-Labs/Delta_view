import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/settings/app_settings.dart';
import 'package:delta_view/ui/settings/settings_page.dart';
import 'package:delta_view/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tab content that does no I/O, so the shell can be driven synchronously.
Widget _page(String text) => Center(child: Text(text));

void main() {
  setUp(() {
    appSettings.recents = [];
    appSettings.sessionTabs = [];
    appSettings.sessionActiveTab = 0;
  });

  Future<TabbedShellState> pumpShell(WidgetTester tester,
      {List<String> notices = const []}) async {
    final key = GlobalKey<TabbedShellState>();
    await tester.pumpWidget(MaterialApp(
      home: TabbedShell(key: key, startupNotices: notices),
    ));
    await tester.pump();
    return key.currentState!;
  }

  testWidgets('starts with one picker tab and opens more', (tester) async {
    final shell = await pumpShell(tester);
    expect(shell.tabs, hasLength(1));
    expect(find.text('DeltaView'), findsOneWidget);

    shell.openTab(title: 'One', icon: Icons.abc, content: _page('one'));
    shell.openTab(title: 'Two', icon: Icons.abc, content: _page('two'));
    await tester.pump();
    expect(shell.tabs, hasLength(3));
    expect(shell.activeIndex, 2);
  });

  testWidgets('a dedupe key focuses the existing tab', (tester) async {
    final shell = await pumpShell(tester);
    shell.openTab(
        title: 'A', icon: Icons.abc, content: _page('a'), dedupeKey: 'a');
    shell.openTab(title: 'B', icon: Icons.abc, content: _page('b'));
    shell.openTab(
        title: 'A', icon: Icons.abc, content: _page('a'), dedupeKey: 'a');
    await tester.pump();
    expect(shell.tabs, hasLength(3));
    expect(shell.activeIndex, 1);
  });

  testWidgets('the settings tab opens once', (tester) async {
    final shell = await pumpShell(tester);
    shell.openSettings();
    await tester.pump();
    shell.openSettings();
    await tester.pump();
    expect(shell.tabs.where((t) => t.dedupeKey == settingsTabKey), hasLength(1));
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('Ctrl+1…9 select tabs', (tester) async {
    final shell = await pumpShell(tester);
    shell.openTab(title: 'One', icon: Icons.abc, content: _page('one'));
    shell.openTab(title: 'Two', icon: Icons.abc, content: _page('two'));
    await tester.pump();
    expect(shell.activeIndex, 2);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(shell.activeIndex, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(shell.activeIndex, 1, reason: 'no ninth tab: nothing changes');
  });

  testWidgets('closing the last tab leaves a fresh picker', (tester) async {
    final shell = await pumpShell(tester);
    final id = shell.tabs.single.id;
    await shell.closeTab(id);
    await tester.pump();
    expect(shell.tabs, hasLength(1));
    expect(shell.tabs.single.id, isNot(id));
  });

  testWidgets('a close guard can keep a tab open', (tester) async {
    final shell = await pumpShell(tester);
    shell.openTab(title: 'Guarded', icon: Icons.abc, content: _page('g'));
    await tester.pump();
    final guarded = shell.tabs.last;
    var asked = 0;
    TabHandle(shell, guarded.id).setCloseGuard(() async {
      asked++;
      return false;
    });

    expect(await shell.closeTab(guarded.id), isFalse);
    expect(await shell.confirmCloseAll(), isFalse);
    expect(asked, 2);
    expect(shell.tabs, hasLength(2));
  });

  testWidgets('startup notices show and can be dismissed', (tester) async {
    await pumpShell(tester, notices: ['Nothing was found at /nope.']);
    expect(find.text('Nothing was found at /nope.'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Nothing was found at /nope.'), findsNothing);
  });

  group('session', () {
    const folders = FolderComparison(LocalSource('/a'), LocalSource('/b'));
    const files = FileComparison(LocalSource('/x'), LocalSource('/y'));

    testWidgets('saveSession writes the open comparisons and active index',
        (tester) async {
      // Comparison tabs do real I/O when shown; run the pump for real.
      await tester.runAsync(() async {
        final key = GlobalKey<TabbedShellState>();
        await tester.pumpWidget(MaterialApp(
          home: TabbedShell(
            key: key,
            initialComparisons: const [folders, files],
            initialActive: 1,
          ),
        ));
        await tester.pump();
        final shell = key.currentState!;
        expect(shell.tabs, hasLength(2));
        expect(shell.activeIndex, 1);

        shell.openTab(title: 'Settings-like', icon: Icons.abc, content: _page('s'));
        await tester.pump();
        shell.selectTab(0);
        await tester.pump();

        shell.saveSession();
        expect(appSettings.sessionTabs, [folders.toJson(), files.toJson()]);
        expect(appSettings.sessionActiveTab, 0);

        // Selecting a tab that is not saved points at the nearest saved one.
        shell.selectTab(2);
        shell.saveSession();
        expect(appSettings.sessionActiveTab, 1);

        // Restored tabs are not pushed into the recent list.
        expect(appSettings.recents, isEmpty);
        // A tab opened by the user is.
        shell.openComparison(
            const FolderComparison(LocalSource('/c'), LocalSource('/d')));
        await tester.pump();
        expect(appSettings.recents, hasLength(1));
        // Opening the same comparison again focuses the tab.
        final count = shell.tabs.length;
        shell.openComparison(folders);
        await tester.pump();
        expect(shell.tabs, hasLength(count));
        expect(shell.activeIndex, 0);
      });
    });

    testWidgets('command-line comparisons go into the recent list',
        (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(
          home: TabbedShell(
            initialComparisons: [folders, files],
            rememberInitial: true,
          ),
        ));
        // Remembering waits for the first frame (see TabbedShellState),
        // which pumpWidget has already drawn.
        await tester.pump();
        expect(appSettings.recents, hasLength(2));
        expect(appSettings.sessionTabs, hasLength(2));
      });
    });
  });
}
