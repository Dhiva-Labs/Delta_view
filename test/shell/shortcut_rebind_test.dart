import 'package:delta_view/settings/app_settings.dart';
import 'package:delta_view/ui/shortcuts/app_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => appSettings.shortcutOverrides = {});
  tearDown(() => appSettings.shortcutOverrides = {});

  test('every default survives serialize / parse', () {
    for (final action in AppAction.values) {
      final text = serializeActivator(action.defaultActivator);
      final back = parseActivator(text)!;
      expect(serializeActivator(back), text, reason: action.name);
      expect(back.trigger, action.defaultActivator.trigger);
      expect(back.control, action.defaultActivator.control);
      expect(back.shift, action.defaultActivator.shift);
      expect(back.alt, action.defaultActivator.alt);
    }
  });

  test('parseActivator rejects garbage', () {
    expect(parseActivator(''), isNull);
    expect(parseActivator('ctrl+zz'), isNull);
  });

  test('rebindAction stores the override and activator follows it', () {
    const custom = SingleActivator(LogicalKeyboardKey.keyK, alt: true);
    expect(AppAction.find.isRebound, isFalse);

    rebindAction(AppAction.find, custom);

    expect(AppAction.find.isRebound, isTrue);
    expect(appSettings.shortcutOverrides['find'], serializeActivator(custom));
    expect(AppAction.find.activator.trigger, LogicalKeyboardKey.keyK);
    expect(AppAction.find.keyLabel, 'Alt+K');
    // The binding map hands out the rebound key.
    expect(bindActions({AppAction.find: () {}}).keys.single, isA<SingleActivator>()
        .having((a) => a.trigger, 'trigger', LogicalKeyboardKey.keyK));
  });

  test('rebinding to the default or to null clears the override', () {
    rebindAction(AppAction.save, const SingleActivator(LogicalKeyboardKey.f2));
    expect(AppAction.save.isRebound, isTrue);

    rebindAction(AppAction.save, AppAction.save.defaultActivator);
    expect(AppAction.save.isRebound, isFalse);

    rebindAction(AppAction.save, const SingleActivator(LogicalKeyboardKey.f2));
    rebindAction(AppAction.save, null);
    expect(AppAction.save.isRebound, isFalse);
    expect(AppAction.save.keyLabel, 'Ctrl+S');
  });

  test('resetAllShortcuts clears everything', () {
    rebindAction(AppAction.save, const SingleActivator(LogicalKeyboardKey.f2));
    rebindAction(AppAction.undo, const SingleActivator(LogicalKeyboardKey.f4));
    resetAllShortcuts();
    expect(appSettings.shortcutOverrides, isEmpty);
  });

  test('conflicts are reported both ways', () {
    expect(conflictingActions(AppAction.find), isEmpty);
    rebindAction(AppAction.find, AppAction.save.defaultActivator);
    expect(conflictingActions(AppAction.find), [AppAction.save]);
    expect(conflictingActions(AppAction.save), [AppAction.find]);
  });

  test('the defaults do not clash with each other', () {
    for (final action in AppAction.values) {
      expect(conflictingActions(action), isEmpty, reason: action.label);
    }
  });

  test('activatorForKey ignores lone modifiers', () {
    expect(activatorForKey(LogicalKeyboardKey.shiftLeft, shift: true), isNull);
    expect(activatorForKey(LogicalKeyboardKey.controlRight, control: true),
        isNull);
    final a = activatorForKey(LogicalKeyboardKey.keyP,
        control: true, shift: true)!;
    expect(describeActivator(a), 'Ctrl+Shift+P');
  });

  test('describeActivator uses readable names', () {
    expect(AppAction.zoomIn.keyLabel, 'Ctrl++');
    expect(AppAction.previousChange.keyLabel, 'Alt+↑');
    expect(AppAction.openSettings.keyLabel, 'Ctrl+,');
    expect(AppAction.findNext.keyLabel, 'F3');
    expect(describeActivator(tabNumberActivator(3)), 'Ctrl+3');
  });

  test('an override saved to JSON comes back', () {
    rebindAction(AppAction.refresh,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true));
    final loaded = AppSettings()..applyJson(appSettings.toJson());
    expect(loaded.shortcutOverrides, appSettings.shortcutOverrides);
  });
}
