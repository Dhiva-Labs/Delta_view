import 'package:delta_view/ui/shortcuts/app_shortcuts.dart';
import 'package:delta_view/ui/shortcuts/key_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<({List<SingleActivator> recorded, List<int> cancelled, int outer})>
      pump(WidgetTester tester) async {
    final recorded = <SingleActivator>[];
    final cancelled = <int>[];
    var outer = 0;
    await tester.pumpWidget(MaterialApp(
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
              outer++,
        },
        child: Scaffold(
          body: ShortcutRecorder(
            onRecorded: recorded.add,
            onCancel: () => cancelled.add(1),
            child: const Text('recording'),
          ),
        ),
      ),
    ));
    await tester.pump();
    return (recorded: recorded, cancelled: cancelled, outer: outer);
  }

  testWidgets('records the first full key combination', (tester) async {
    final r = await pump(tester);
    // A lone modifier is not a shortcut.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(r.recorded, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(r.recorded, hasLength(1));
    expect(describeActivator(r.recorded.single), 'Ctrl+K');
    expect(r.cancelled, isEmpty);
  });

  testWidgets('Escape cancels', (tester) async {
    final r = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(r.cancelled, hasLength(1));
    expect(r.recorded, isEmpty);
  });

  testWidgets('keys pressed while recording do not reach app shortcuts',
      (tester) async {
    final recorded = <SingleActivator>[];
    var outer = 0;
    await tester.pumpWidget(MaterialApp(
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
              outer++,
        },
        child: Scaffold(
          body: ShortcutRecorder(
            onRecorded: recorded.add,
            onCancel: () {},
            child: const Text('recording'),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(recorded, hasLength(1));
    expect(outer, 0, reason: 'Ctrl+W must not close a tab while recording');
  });
}
