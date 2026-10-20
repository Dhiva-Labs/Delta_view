/// The settings tab: every preference, applied live and saved through
/// [AppSettings.changed]. Wide windows get a section index on the left.
library;

import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import 'appearance_section.dart';
import 'behaviour_section.dart';
import 'editor_section.dart';
import 'folders_section.dart';
import 'keyboard_section.dart';
import 'rules_section.dart';

/// Dedupe key of the settings tab: opening it twice focuses the first.
const settingsTabKey = 'settings';

enum SettingsSectionId {
  appearance('Appearance', Icons.palette_outlined),
  editor('Editor', Icons.code),
  rules('Comparison rules', Icons.rule),
  folders('Folders', Icons.folder_copy_outlined),
  behaviour('Behaviour', Icons.tune),
  keyboard('Keyboard', Icons.keyboard_outlined);

  const SettingsSectionId(this.label, this.icon);

  final String label;
  final IconData icon;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialSection});

  /// Scrolled to on open (e.g. Keyboard from the shortcut overlay).
  final SettingsSectionId? initialSection;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _scroll = ScrollController();
  final _keys = {
    for (final id in SettingsSectionId.values) id: GlobalKey(),
  };
  SettingsSectionId _current = SettingsSectionId.appearance;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSection;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(initial));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpTo(SettingsSectionId id) {
    setState(() => _current = id);
    final context = _keys[id]!.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  Widget _section(SettingsSectionId id) => switch (id) {
        SettingsSectionId.appearance => const AppearanceSection(),
        SettingsSectionId.editor => const EditorSection(),
        SettingsSectionId.rules => const RulesSection(),
        SettingsSectionId.folders => const FoldersSection(),
        SettingsSectionId.behaviour => const BehaviourSection(),
        SettingsSectionId.keyboard => const KeyboardSection(),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 820;
            final content = Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                    wide ? 32 : 16, 24, wide ? 32 : 16, 48),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Settings',
                            style: textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('Changes apply straight away and are saved.',
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant)),
                        if (!wide) ...[
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final id in SettingsSectionId.values)
                                ActionChip(
                                  avatar: Icon(id.icon, size: 16),
                                  label: Text(id.label),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _jumpTo(id),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        for (final id in SettingsSectionId.values)
                          Padding(
                            key: _keys[id],
                            padding: const EdgeInsets.only(bottom: 28),
                            child: _section(id),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            if (!wide) return content;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 210,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 28, 0, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final id in SettingsSectionId.values)
                          _NavItem(
                            id: id,
                            selected: _current == id,
                            onTap: () => _jumpTo(id),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(child: content),
              ],
            );
          },
        );
      },
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final SettingsSectionId id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.5)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(id.icon,
                    size: 18,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Text(
                  id.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
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
