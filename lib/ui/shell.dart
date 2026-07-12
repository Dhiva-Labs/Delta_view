import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import 'picker_view.dart';

/// Browser-style tabbed shell: every comparison lives in its own tab so
/// several can be open at once. Ctrl+T opens a tab, Ctrl+W closes one.
class TabbedShell extends StatefulWidget {
  const TabbedShell({super.key});

  @override
  State<TabbedShell> createState() => TabbedShellState();
}

class TabData {
  TabData({
    required this.id,
    required this.title,
    required this.icon,
    required this.content,
  });

  final int id;
  String title;
  IconData icon;
  final Widget content;
}

class TabbedShellState extends State<TabbedShell> {
  final List<TabData> _tabs = [];
  int _active = 0;
  int _nextId = 0;

  static TabbedShellState of(BuildContext context) =>
      context.findAncestorStateOfType<TabbedShellState>()!;

  @override
  void initState() {
    super.initState();
    newPickerTab();
  }

  void newPickerTab() {
    final id = _nextId++;
    setState(() {
      _tabs.add(TabData(
        id: id,
        title: 'New comparison',
        icon: Icons.add_circle_outline,
        content: TabRoot(key: ValueKey('tab-$id'), tabId: id),
      ));
      _active = _tabs.length - 1;
    });
  }

  /// Opens an arbitrary view (e.g. a file diff spawned from a folder tree)
  /// in a fresh tab and switches to it.
  void openTab({
    required String title,
    required IconData icon,
    required Widget content,
  }) {
    final id = _nextId++;
    setState(() {
      _tabs.add(TabData(
        id: id,
        title: title,
        icon: icon,
        content: KeyedSubtree(key: ValueKey('tab-$id'), child: content),
      ));
      _active = _tabs.length - 1;
    });
  }

  void updateTab(int id, {String? title, IconData? icon}) {
    final tab = _tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    setState(() {
      if (title != null) tab.title = title;
      if (icon != null) tab.icon = icon;
    });
  }

  void closeTab(int id) {
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        // Always keep at least one tab alive.
        _active = 0;
      } else if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (index < _active) {
        _active--;
      }
    });
    if (_tabs.isEmpty) newPickerTab();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT, control: true):
            newPickerTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (_tabs.isNotEmpty) closeTab(_tabs[_active].id);
        },
      },
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
                      tooltip: 'New comparison (Ctrl+T)',
                      onPressed: newPickerTab,
                      icon: const Icon(Icons.add, size: 20),
                    ),
                    IconButton(
                      tooltip: isDark ? 'Light theme' : 'Dark theme',
                      onPressed: () {
                        themeModeNotifier.value =
                            isDark ? ThemeMode.light : ThemeMode.dark;
                      },
                      icon: Icon(
                        isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 20,
                      ),
                    ),
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
                  child: Icon(Icons.close,
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
