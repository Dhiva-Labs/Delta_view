import 'dart:convert';

import 'package:flutter/material.dart';

import '../compare/comparison.dart';
import '../settings/app_settings.dart';
import 'comparison_view.dart';
import 'picker_view.dart';
import 'shortcuts/app_shortcuts.dart';

/// Browser-style tabbed shell: every comparison lives in its own tab so
/// several can be open at once.
class TabbedShell extends StatefulWidget {
  const TabbedShell({super.key, this.initialComparisons = const []});

  /// Opened at start-up (e.g. from the command line), each in its own tab.
  final List<Comparison> initialComparisons;

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

  /// What the tab currently compares (null while it shows the picker).
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

class TabbedShellState extends State<TabbedShell> {
  final List<TabData> _tabs = [];
  int _active = 0;
  int _nextId = 0;

  static TabbedShellState of(BuildContext context) =>
      context.findAncestorStateOfType<TabbedShellState>()!;

  List<TabData> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _active;

  @override
  void initState() {
    super.initState();
    for (final c in widget.initialComparisons) {
      openComparison(c);
    }
    if (_tabs.isEmpty) newPickerTab();
  }

  int _add(TabData Function(int id) build) {
    final id = _nextId++;
    setState(() {
      _tabs.add(build(id));
      _active = _tabs.length - 1;
    });
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
  /// shows it.
  void openComparison(Comparison comparison, {String? title}) {
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
    _remember(comparison);
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
    _update(id, (t) {
      t.comparison = comparison;
      t.dedupeKey = comparison == null ? null : comparisonKey(comparison);
      t.title = comparison?.title ?? 'New comparison';
      t.icon = comparison == null
          ? Icons.add_circle_outline
          : comparisonIcon(comparison);
    });
    if (comparison != null) _remember(comparison);
  }

  void _remember(Comparison comparison) {
    if (comparison.rememberable && comparison is! TextComparison) {
      appSettings.addRecent(comparison.toJson());
    }
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.newTab: newPickerTab,
        AppAction.closeTab: () {
          if (_tabs.isNotEmpty) closeTab(_tabs[_active].id);
        },
        AppAction.nextTab: () => cycleTab(1),
        AppAction.previousTab: () => cycleTab(-1),
      }),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _tabs.length,
                        itemBuilder: (context, index) => _TabChip(
                          data: _tabs[index],
                          active: index == _active,
                          onSelect: () => setState(() => _active = index),
                          onClose: () => closeTab(_tabs[index].id),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'New comparison (${AppAction.newTab.keyLabel})',
                      onPressed: newPickerTab,
                      icon: const Icon(Icons.add, size: 20),
                    ),
                    const _ThemeButton(),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              Expanded(
                child: IndexedStack(
                  index: _active < _tabs.length ? _active : 0,
                  children: [for (final tab in _tabs) tab.content],
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

class _ThemeButton extends StatelessWidget {
  const _ThemeButton();

  @override
  Widget build(BuildContext context) {
    final mode = appSettings.themeMode;
    final (icon, next, label) = switch (mode) {
      ThemeMode.system => (
          Icons.brightness_auto_outlined,
          ThemeMode.light,
          'Theme: follows system'
        ),
      ThemeMode.light => (
          Icons.light_mode_outlined,
          ThemeMode.dark,
          'Theme: light'
        ),
      ThemeMode.dark => (
          Icons.dark_mode_outlined,
          ThemeMode.system,
          'Theme: dark'
        ),
    };
    return IconButton(
      tooltip: label,
      onPressed: () {
        appSettings.themeMode = next;
        appSettings.changed();
      },
      icon: Icon(icon, size: 20),
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        onTertiaryTapUp: (_) => widget.onClose(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          padding: const EdgeInsets.only(left: 12, right: 6),
          constraints: const BoxConstraints(maxWidth: 220, minWidth: 120),
          decoration: BoxDecoration(
            color: active
                ? scheme.primaryContainer.withValues(alpha: 0.55)
                : _hovered
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
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
                    color: active ? scheme.onSurface : scheme.onSurfaceVariant,
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
    );
  }
}
