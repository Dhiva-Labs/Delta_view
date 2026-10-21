/// Every keyboard shortcut in the app, with its default key and the label
/// shown in the shortcut list and the settings page. Users can rebind any
/// of them; views ask [AppAction.activator] instead of hard-coding keys.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../settings/app_settings.dart';

enum ShortcutGroup {
  tabs('Tabs and app'),
  navigation('Navigation'),
  editing('Editing and merging'),
  view('View'),
  folders('Folder tree');

  const ShortcutGroup(this.label);

  final String label;
}

enum AppAction {
  // tabs & app
  newTab('New comparison tab', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.keyT, control: true)),
  closeTab('Close tab', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.keyW, control: true)),
  nextTab('Next tab', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.tab, control: true)),
  previousTab('Previous tab', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true)),
  openSettings('Settings', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.comma, control: true)),
  showShortcuts('Keyboard shortcuts', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.slash, control: true)),
  compareClipboard('Compare text from clipboard', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true)),
  quit('Quit DeltaView', ShortcutGroup.tabs,
      SingleActivator(LogicalKeyboardKey.keyQ, control: true)),

  // navigation in a diff
  nextChange('Next change', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.arrowDown, alt: true)),
  previousChange('Previous change', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.arrowUp, alt: true)),
  find('Find', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.keyF, control: true)),
  findNext('Find next', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.f3)),
  findPrevious('Find previous', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.f3, shift: true)),
  goToLine('Go to line', ShortcutGroup.navigation,
      SingleActivator(LogicalKeyboardKey.keyG, control: true)),

  // editing / merging
  save('Save', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.keyS, control: true)),
  toggleEdit('Switch between view and edit', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.keyE, control: true)),
  copyToRight('Copy change to the right', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.arrowRight, alt: true)),
  copyToLeft('Copy change to the left', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true)),
  undo('Undo', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.keyZ, control: true)),
  redo('Redo', ShortcutGroup.editing,
      SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true)),

  // view
  zoomIn('Bigger text', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.equal, control: true)),
  zoomOut('Smaller text', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.minus, control: true)),
  zoomReset('Reset text size', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.digit0, control: true)),
  toggleWrap('Wrap long lines', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.keyW, alt: true)),
  toggleFold('Hide unchanged lines', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.keyU, alt: true)),
  refresh('Compare again', ShortcutGroup.view,
      SingleActivator(LogicalKeyboardKey.f5)),

  // folder tree
  openEntry('Open the selected entry', ShortcutGroup.folders,
      SingleActivator(LogicalKeyboardKey.enter)),
  expandAll('Expand all folders', ShortcutGroup.folders,
      SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true)),
  collapseAll('Collapse all folders', ShortcutGroup.folders,
      SingleActivator(LogicalKeyboardKey.minus, control: true, shift: true)),
  syncFolders('Synchronize folders', ShortcutGroup.folders,
      SingleActivator(LogicalKeyboardKey.keyY, control: true, shift: true));

  const AppAction(this.label, this.group, this.defaultActivator);

  final String label;
  final ShortcutGroup group;
  final SingleActivator defaultActivator;

  /// The key the user bound, or the default.
  SingleActivator get activator {
    final override = appSettings.shortcutOverrides[name];
    return (override == null ? null : parseActivator(override)) ??
        defaultActivator;
  }

  /// e.g. `Ctrl+Shift+V`.
  String get keyLabel => describeActivator(activator);

  /// Whether the user changed this action's key.
  bool get isRebound => appSettings.shortcutOverrides.containsKey(name);

  /// The actions in [group], in declaration order.
  static List<AppAction> inGroup(ShortcutGroup group) =>
      [for (final a in values) if (a.group == group) a];
}

/// Builds a [CallbackShortcuts] binding map from actions to callbacks,
/// honouring the user's rebinds.
Map<ShortcutActivator, VoidCallback> bindActions(
        Map<AppAction, VoidCallback> actions) =>
    {for (final e in actions.entries) e.key.activator: e.value};

/// Ctrl+1 … Ctrl+9 switch to that tab. Fixed rather than an [AppAction],
/// so the rebindable list is not nine near-identical rows.
SingleActivator tabNumberActivator(int number) => SingleActivator(
      LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + number - 1),
      control: true,
    );

const tabNumberKeyLabel = 'Ctrl+1…9';

/// Binds [action] to [activator], or restores its default with null, and
/// saves the change.
void rebindAction(AppAction action, SingleActivator? activator) {
  if (activator == null ||
      serializeActivator(activator) ==
          serializeActivator(action.defaultActivator)) {
    appSettings.shortcutOverrides.remove(action.name);
  } else {
    appSettings.shortcutOverrides[action.name] = serializeActivator(activator);
  }
  appSettings.changed();
}

void resetAllShortcuts() {
  appSettings.shortcutOverrides.clear();
  appSettings.changed();
}

/// The other actions currently bound to the same key as [action]. Views
/// bind only the actions they use, so a clash is not always a problem,
/// but the settings page warns about it.
List<AppAction> conflictingActions(AppAction action) {
  final key = serializeActivator(action.activator);
  return [
    for (final other in AppAction.values)
      if (other != action && serializeActivator(other.activator) == key) other,
  ];
}

/// `ctrl+shift+keyV`-style text: modifiers then the [LogicalKeyboardKey]
/// key id in hex. Stable across platforms and keyboard layouts.
String serializeActivator(SingleActivator a) => [
      if (a.control) 'ctrl',
      if (a.shift) 'shift',
      if (a.alt) 'alt',
      if (a.meta) 'meta',
      a.trigger.keyId.toRadixString(16),
    ].join('+');

SingleActivator? parseActivator(String text) {
  final parts = text.split('+');
  if (parts.isEmpty) return null;
  final id = int.tryParse(parts.last, radix: 16);
  if (id == null) return null;
  final key = LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
  final mods = parts.sublist(0, parts.length - 1).toSet();
  return SingleActivator(
    key,
    control: mods.contains('ctrl'),
    shift: mods.contains('shift'),
    alt: mods.contains('alt'),
    meta: mods.contains('meta'),
  );
}

String describeActivator(SingleActivator a) {
  final key = switch (a.trigger) {
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.equal => '+',
    LogicalKeyboardKey.minus => '−',
    LogicalKeyboardKey.comma => ',',
    LogicalKeyboardKey.period => '.',
    LogicalKeyboardKey.slash => '/',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.escape => 'Esc',
    final k => k.keyLabel.isEmpty ? k.debugName ?? '?' : k.keyLabel,
  };
  return [
    if (a.control) 'Ctrl',
    if (a.shift) 'Shift',
    if (a.alt) 'Alt',
    if (a.meta) 'Meta',
    key,
  ].join('+');
}

/// Keys that only modify others; pressing one on its own is not a
/// shortcut. (Not const: LogicalKeyboardKey overrides ==.)
final _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.altGraph,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.numLock,
  LogicalKeyboardKey.scrollLock,
  LogicalKeyboardKey.fn,
};

/// The activator a key press describes, or null when [key] is a modifier
/// on its own. Used when the user records a new shortcut.
SingleActivator? activatorForKey(
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
  bool alt = false,
  bool meta = false,
}) {
  if (_modifierKeys.contains(key)) return null;
  return SingleActivator(key,
      control: control, shift: shift, alt: alt, meta: meta);
}

/// [activatorForKey] for a live [KeyEvent], reading the modifiers that are
/// held right now.
SingleActivator? activatorForKeyEvent(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  return activatorForKey(
    event.logicalKey,
    control: keyboard.isControlPressed,
    shift: keyboard.isShiftPressed,
    alt: keyboard.isAltPressed,
    meta: keyboard.isMetaPressed,
  );
}
