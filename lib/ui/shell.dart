import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compare/comparison.dart';
import '../settings/app_settings.dart';
import 'about/about_dialog.dart';
import 'brand/app_logo.dart';
import 'comparison_view.dart';
import 'picker_view.dart';
import 'settings/settings_page.dart';
import 'shortcuts/app_shortcuts.dart';
import 'shortcuts/shortcuts_overlay.dart';

/// Browser-style tabbed shell: every comparison lives in its own tab so
/// several can be open at once.
class TabbedShell extends StatefulWidget {
  const TabbedShell({
    super.key,
    this.initialComparisons = const [],
    this.initialActive = 0,
    this.rememberInitial = false,
    this.startupNotices = const [],
    this.onQuitRequested,
  });

  /// Opened at start-up (from the command line or the last session), each
  /// in its own tab.
  final List<Comparison> initialComparisons;

  /// Which of [initialComparisons] starts selected.
  final int initialActive;

  /// Whether [initialComparisons] go into the recent list: true for ones
  /// the user asked for on the command line, false for a restored session
  /// (reopening the app should not bump every entry to "just now").
  final bool rememberInitial;

  /// Friendly messages about start-up arguments that could not be opened.
  final List<String> startupNotices;

  /// Ctrl+Q. Asks the window to close, which runs the close guards; null
  /// (in tests) disables the shortcut.
  final VoidCallback? onQuitRequested;

  @override
  State<TabbedShell> createState() => TabbedShellState();
}

class TabData {
  TabData({
    required this.id,
    required this.title,
    required this.icon,
    required this.content,
    this.dedupeKey,
    this.comparison,
  });

  final int id;
  String title;
  IconData icon;
  final Widget content;

  /// Tabs opened with the same key are focused instead of duplicated.
  String? dedupeKey;

  /// What the tab currently compares (null while it shows the picker or
  /// something that is not a comparison, like settings).
  Comparison? comparison;

  /// Unsaved edits: shown as a dot on the tab.
  bool dirty = false;

  /// Asked before the tab closes; returns false to keep it open. Views with
  /// unsaved work register one through [TabScope].
  Future<bool> Function()? closeGuard;
}

/// Gives the views inside a tab a handle on that tab: mark it dirty,
/// register a close guard, retitle it.
class TabScope extends InheritedWidget {
  const TabScope({super.key, required this.handle, required super.child});

  final TabHandle handle;

  static TabHandle? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TabScope>()?.handle;

  @override
  bool updateShouldNotify(TabScope oldWidget) => oldWidget.handle != handle;
}

class TabHandle {
  TabHandle(this._shell, this.tabId);

  final TabbedShellState _shell;
  final int tabId;

  void setDirty(bool dirty) => _shell._update(tabId, (t) => t.dirty = dirty);

  /// [guard] runs before the tab (or the app) closes; null removes it.
  void setCloseGuard(Future<bool> Function()? guard) =>
      _shell._update(tabId, (t) => t.closeGuard = guard, rebuild: false);

  void setComparison(Comparison? comparison) =>
      _shell._setComparison(tabId, comparison);
}

/// What the shell writes to [AppSettings.sessionTabs]: the comparisons of
/// the tabs that have one and are worth remembering.
List<Map<String, Object?>> sessionJsonOf(Iterable<Comparison?> tabs) => [
      for (final c in tabs)
        if (c != null && c.rememberable) c.toJson(),
    ];

/// The tabs to reopen from [settings], with the index to select. Entries
/// written by a newer version (unknown types) are skipped.
({List<Comparison> comparisons, int active}) restoreSession(
    AppSettings settings) {
  final comparisons = [
    for (final json in settings.sessionTabs) ?Comparison.fromJson(json),
  ];
  final active = comparisons.isEmpty
      ? 0
      : settings.sessionActiveTab.clamp(0, comparisons.length - 1);
  return (comparisons: comparisons, active: active);
}

class TabbedShellState extends State<TabbedShell> {
  final List<TabData> _tabs = [];
  int _active = 0;
  int _nextId = 0;
  late final List<String> _notices = [...widget.startupNotices];

  static TabbedShellState of(BuildContext context) =>
      context.findAncestorStateOfType<TabbedShellState>()!;

  List<TabData> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _active;

  /// True while initState opens the start-up tabs: touching [appSettings]
  /// then would notify the app-level listener in the middle of the first
  /// build, so remembering and saving wait for the first frame.
  bool _starting = false;
  final List<Comparison> _rememberLater = [];

  @override
  void initState() {
    super.initState();
    _starting = true;
    for (final c in widget.initialComparisons) {
      openComparison(c, remember: widget.rememberInitial);
    }
    if (_tabs.isEmpty) {
      newPickerTab();
    } else {
      _active = widget.initialActive.clamp(0, _tabs.length - 1);
    }
    _starting = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final c in _rememberLater) {
        _remember(c);
      }
      _rememberLater.clear();
      _persistSession();
    });
  }

  int _add(TabData Function(int id) build) {
    final id = _nextId++;
    setState(() {
      _tabs.add(build(id));
      _active = _tabs.length - 1;
    });
    _persistSession();
    return id;
  }

  Widget _scoped(int id, Widget child) => TabScope(
        key: ValueKey('tab-$id'),
        handle: TabHandle(this, id),
        child: child,
      );

  void newPickerTab() {
    _add((id) => TabData(
          id: id,
          title: 'New comparison',
          icon: Icons.add_circle_outline,
          content: _scoped(id, TabRoot(tabId: id)),
        ));
  }

  /// Opens [comparison] in a new tab, or focuses the tab that already
  /// shows it. [remember] adds it to the recent list (see
  /// [TabbedShell.rememberInitial] for why session restore passes false).
  void openComparison(Comparison comparison,
      {String? title, bool remember = true}) {
    final key = comparisonKey(comparison);
    if (focusTab(key)) return;
    _add((id) => TabData(
          id: id,
          title: title ?? comparison.title,
          icon: comparisonIcon(comparison),
          dedupeKey: key,
          comparison: comparison,
          content: _scoped(id, TabRoot(tabId: id, initial: comparison)),
        ));
    if (remember) _remember(comparison);
  }

  /// Opens an arbitrary view in a fresh tab and switches to it. With a
  /// [dedupeKey], an existing tab with the same key is focused instead.
  void openTab({
    required String title,
    required IconData icon,
    required Widget content,
    String? dedupeKey,
  }) {
    if (dedupeKey != null && focusTab(dedupeKey)) return;
    _add((id) => TabData(
          id: id,
          title: title,
          icon: icon,
          dedupeKey: dedupeKey,
          content: _scoped(id, content),
        ));
  }

  /// The settings tab (one at most), optionally scrolled to [section].
  void openSettings({SettingsSectionId? section}) {
    openTab(
      title: 'Settings',
      icon: Icons.settings_outlined,
      dedupeKey: settingsTabKey,
      content: SettingsPage(initialSection: section),
    );
  }

  void showShortcuts() {
    showShortcutsOverlay(
      context,
      onOpenSettings: () => openSettings(section: SettingsSectionId.keyboard),
    );
  }

  void showAbout() => showAboutDeltaView(context);

  /// Ctrl+Shift+V: a text comparison with the clipboard on the left, ready
  /// for the second paste.
  Future<void> compareClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    openComparison(TextComparison(leftText: data?.text ?? ''));
  }

  /// Switches to the tab with [dedupeKey]; false when there is none.
  bool focusTab(String dedupeKey) {
    final index = _tabs.indexWhere((t) => t.dedupeKey == dedupeKey);
    if (index < 0) return false;
    setState(() => _active = index);
    return true;
  }

  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() => _active = index);
  }

  void cycleTab(int delta) {
    if (_tabs.isEmpty) return;
    setState(() => _active = (_active + delta) % _tabs.length);
  }

  void updateTab(int id, {String? title, IconData? icon}) {
    _update(id, (t) {
      if (title != null) t.title = title;
      if (icon != null) t.icon = icon;
    });
  }

  void _update(int id, void Function(TabData tab) change,
      {bool rebuild = true}) {
    final tab = _tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    if (rebuild && mounted) {
      setState(() => change(tab));
    } else {
      change(tab);
    }
  }

  void _setComparison(int id, Comparison? comparison) {
    final key = comparison == null ? null : comparisonKey(comparison);
    var changed = false;
    _update(id, (t) {
      changed = t.dedupeKey != key;
      t.comparison = comparison;
      t.dedupeKey = key;
      t.title = comparison?.title ?? 'New comparison';
      t.icon = comparison == null
          ? Icons.add_circle_outline
          : comparisonIcon(comparison);
    });
    if (comparison != null && changed) _remember(comparison);
    _persistSession();
  }

  void _remember(Comparison comparison) {
    if (!comparison.rememberable || comparison is TextComparison) return;
    if (_starting) {
      _rememberLater.add(comparison);
      return;
    }
    appSettings.addRecent(comparison.toJson());
  }

  // ---- session ----

  /// Writes the open comparisons to the settings model. Called whenever
  /// tabs change, so a crash loses nothing, and once more on quit.
  void saveSession() {
    final saved = <Map<String, Object?>>[];
    var active = 0;
    for (var i = 0; i < _tabs.length; i++) {
      final c = _tabs[i].comparison;
      if (c == null || !c.rememberable) continue;
      if (i <= _active) active = saved.length;
      saved.add(c.toJson());
    }
    appSettings.sessionTabs = saved;
    appSettings.sessionActiveTab = saved.isEmpty ? 0 : active.clamp(0, saved.length - 1);
  }

  void _persistSession() {
    if (_starting) return;
    saveSession();
    // Through changed(): the settings model owns one debounced writer, and
    // two flushes in flight would race for the same temporary file.
    appSettings.changed();
  }

  /// Closes the tab unless its close guard says no. Returns whether it
  /// closed.
  Future<bool> closeTab(int id) async {
    final tab = _tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return true;
    final guard = tab.closeGuard;
    if (guard != null) {
      final index = _tabs.indexOf(tab);
      if (index >= 0 && index != _active) setState(() => _active = index);
      if (!await guard()) return false;
    }
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return true;
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _active = 0;
      } else if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (index < _active) {
        _active--;
      }
    });
    if (_tabs.isEmpty) newPickerTab();
    _persistSession();
    return true;
  }

  /// Runs every tab's close guard (for quitting the app). False when the
  /// user chose to keep any tab open.
  Future<bool> confirmCloseAll() async {
    for (var i = 0; i < _tabs.length; i++) {
      final guard = _tabs[i].closeGuard;
      if (guard == null) continue;
      setState(() => _active = i);
      if (!await guard()) return false;
    }
    return true;
  }

  Map<ShortcutActivator, VoidCallback> _bindings() {
    final bindings = bindActions({
      AppAction.newTab: newPickerTab,
      AppAction.closeTab: () {
        if (_tabs.isNotEmpty) closeTab(_tabs[_active].id);
      },
      AppAction.nextTab: () => cycleTab(1),
      AppAction.previousTab: () => cycleTab(-1),
      AppAction.openSettings: openSettings,
      AppAction.showShortcuts: showShortcuts,
      AppAction.compareClipboard: compareClipboard,
      if (widget.onQuitRequested != null)
        AppAction.quit: widget.onQuitRequested!,
    });
    for (var n = 1; n <= 9; n++) {
      bindings[tabNumberActivator(n)] = () => selectTab(n - 1);
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _TabBar(
                tabs: _tabs,
                active: _active,
                onSelect: selectTab,
                onClose: (index) => closeTab(_tabs[index].id),
                onNew: newPickerTab,
                onSettings: openSettings,
                onShortcuts: showShortcuts,
                onAbout: showAbout,
              ),
              for (var i = 0; i < _notices.length; i++)
                _NoticeBar(
                  message: _notices[i],
                  onDismiss: () => setState(() => _notices.removeAt(i)),
                ),
              Expanded(
                child: ColoredBox(
                  color: scheme.surface,
                  child: IndexedStack(
                    index: _active < _tabs.length ? _active : 0,
                    children: [for (final tab in _tabs) tab.content],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stable identity of a comparison, for tab de-duplication and recents.
String comparisonKey(Comparison comparison) =>
    jsonEncode(comparison.toJson());

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onSettings,
    required this.onShortcuts,
    required this.onAbout,
  });

  final List<TabData> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  final VoidCallback onShortcuts;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 12, right: 6),
            child: AppLogo.glyph(size: 18),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              itemCount: tabs.length,
              itemBuilder: (context, index) => _TabChip(
                data: tabs[index],
                active: index == active,
                onSelect: () => onSelect(index),
                onClose: () => onClose(index),
              ),
            ),
          ),
          IconButton(
            tooltip: 'New comparison (${AppAction.newTab.keyLabel})',
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 20),
          ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          const _ThemeMenu(),
          IconButton(
            tooltip: 'Settings (${AppAction.openSettings.keyLabel})',
            onPressed: onSettings,
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.keyboard_outlined),
                trailingIcon: Text(AppAction.showShortcuts.keyLabel,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
                onPressed: onShortcuts,
                child: const Text('Keyboard shortcuts'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.info_outline),
                onPressed: onAbout,
                child: const Text('About DeltaView'),
              ),
            ],
            builder: (context, controller, _) => IconButton(
              tooltip: 'More',
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.more_vert, size: 20),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer.withValues(alpha: 0.6),
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onErrorContainer)),
          ),
          IconButton(
            tooltip: 'Dismiss',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

class _ThemeMenu extends StatelessWidget {
  const _ThemeMenu();

  static const _modes = [
    (ThemeMode.system, 'System', Icons.brightness_auto_outlined),
    (ThemeMode.light, 'Light', Icons.light_mode_outlined),
    (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        final current = _modes.firstWhere((m) => m.$1 == appSettings.themeMode);
        return MenuAnchor(
          menuChildren: [
            for (final (mode, label, icon) in _modes)
              MenuItemButton(
                leadingIcon: Icon(icon),
                trailingIcon: mode == appSettings.themeMode
                    ? Icon(Icons.check, size: 18, color: scheme.primary)
                    : const SizedBox(width: 18),
                onPressed: () {
                  appSettings.themeMode = mode;
                  appSettings.changed();
                },
                child: Text(label),
              ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: 'Theme: ${current.$2.toLowerCase()}',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: Icon(current.$3, size: 20),
          ),
        );
      },
    );
  }
}

class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.data,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });

  final TabData data;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.active;
    final dirty = widget.data.dirty;
    final comparison = widget.data.comparison;
    final tooltip = switch (comparison) {
      FolderComparison c => '${c.left.description}\n${c.right.description}',
      FileComparison c => '${c.left.description}\n${c.right.description}',
      ThreeWayComparison c =>
        '${c.left.description}\n${c.base.description}\n${c.right.description}',
      _ => widget.data.title,
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        onTertiaryTapUp: (_) => widget.onClose(),
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 900),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
            padding: const EdgeInsets.only(left: 12, right: 6),
            constraints: const BoxConstraints(maxWidth: 220, minWidth: 110),
            decoration: BoxDecoration(
              color: active
                  ? scheme.surface
                  : _hovered
                      ? scheme.surfaceContainerHigh.withValues(alpha: 0.7)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: active
                    ? scheme.outlineVariant.withValues(alpha: 0.7)
                    : Colors.transparent,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: 0.06),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.data.icon,
                    size: 15,
                    color: active ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    widget.data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color:
                          active ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.onClose,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: dirty && !_hovered
                        ? Icon(Icons.circle, size: 9, color: scheme.primary)
                        : Icon(Icons.close,
                            size: 13,
                            color: _hovered || active
                                ? scheme.onSurfaceVariant
                                : Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
