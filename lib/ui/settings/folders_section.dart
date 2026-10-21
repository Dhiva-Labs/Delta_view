import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import 'settings_widgets.dart';

/// The patterns a fresh [AppSettings] starts with. A new instance never
/// touches disk, so this is the cheapest source of truth.
List<String> get defaultIgnorePatterns => AppSettings().ignorePatterns;

class FoldersSection extends StatefulWidget {
  const FoldersSection({super.key});

  @override
  State<FoldersSection> createState() => _FoldersSectionState();
}

class _FoldersSectionState extends State<FoldersSection> {
  final _pattern = TextEditingController();
  final _patternFocus = FocusNode();

  @override
  void dispose() {
    _pattern.dispose();
    _patternFocus.dispose();
    super.dispose();
  }

  void _save() => appSettings.changed();

  void _addPattern() {
    final text = _pattern.text.trim();
    if (text.isEmpty) return;
    if (!appSettings.ignorePatterns.contains(text)) {
      appSettings.ignorePatterns.add(text);
      _save();
    }
    _pattern.clear();
    _patternFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final patterns = appSettings.ignorePatterns;
    final defaults = defaultIgnorePatterns;
    final isDefault = patterns.length == defaults.length &&
        [for (var i = 0; i < patterns.length; i++) patterns[i] == defaults[i]]
            .every((same) => same);

    return SettingsSection(
      title: 'Folders',
      icon: Icons.folder_copy_outlined,
      children: [
        SettingRow(
          label: 'Ignored names',
          description:
              'Files and folders matching these are left out of folder '
              'comparisons. * and ? are wildcards.',
          control: isDefault
              ? null
              : TextButton(
                  onPressed: () {
                    appSettings.ignorePatterns = defaultIgnorePatterns;
                    _save();
                  },
                  child: const Text('Reset to defaults'),
                ),
          below: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (patterns.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final pattern in patterns)
                      InputChip(
                        label: Text(pattern,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        onDeleted: () {
                          appSettings.ignorePatterns.remove(pattern);
                          _save();
                        },
                      ),
                  ],
                )
              else
                Text('Nothing is ignored.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      controller: _pattern,
                      focusNode: _patternFocus,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12.5),
                      onSubmitted: (_) => _addPattern(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'e.g. *.log or build',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _addPattern,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
        SwitchRow(
          label: 'Respect .gitignore',
          description: 'Skip whatever each folder\'s .gitignore excludes.',
          value: appSettings.respectGitignore,
          onChanged: (v) {
            appSettings.respectGitignore = v;
            _save();
          },
        ),
        ChoiceRow<FolderCompareMethod>(
          label: 'Compare files by',
          description: 'How two files with the same name are judged the same.',
          value: appSettings.folderCompareMethod,
          width: 220,
          options: const [
            (FolderCompareMethod.content, 'Content (exact)'),
            (FolderCompareMethod.sizeAndDate, 'Size and date (fast)'),
          ],
          onChanged: (v) {
            appSettings.folderCompareMethod = v;
            _save();
          },
        ),
        ChoiceRow<FolderFilterDefault>(
          label: 'Default filter',
          description: 'What a new folder comparison shows first.',
          value: appSettings.defaultFolderFilter,
          options: const [
            (FolderFilterDefault.all, 'Everything'),
            (FolderFilterDefault.changes, 'Changes only'),
            (FolderFilterDefault.leftOnly, 'Only on the left'),
            (FolderFilterDefault.rightOnly, 'Only on the right'),
          ],
          onChanged: (v) {
            appSettings.defaultFolderFilter = v;
            _save();
          },
        ),
        ChoiceRow<DateStyle>(
          label: 'Dates',
          value: appSettings.dateStyle,
          options: const [
            (DateStyle.short, '21 Oct 2026 14:05'),
            (DateStyle.iso, '2026-10-21 14:05'),
            (DateStyle.relative, '3 hours ago'),
          ],
          onChanged: (v) {
            appSettings.dateStyle = v;
            _save();
          },
        ),
      ],
    );
  }
}
