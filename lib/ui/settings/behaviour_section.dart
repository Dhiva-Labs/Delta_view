import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import 'settings_widgets.dart';

class BehaviourSection extends StatefulWidget {
  const BehaviourSection({super.key});

  @override
  State<BehaviourSection> createState() => _BehaviourSectionState();
}

class _BehaviourSectionState extends State<BehaviourSection> {
  late final _editor = TextEditingController(text: appSettings.externalEditor);

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsSection(
      title: 'Behaviour',
      icon: Icons.tune,
      children: [
        SwitchRow(
          label: 'Restore the last session',
          description: 'Reopen the comparisons that were open when '
              'DeltaView was closed.',
          value: appSettings.restoreSession,
          onChanged: (v) {
            appSettings.restoreSession = v;
            appSettings.changed();
          },
        ),
        SettingRow(
          label: 'External editor',
          description: 'Used by "Open in external editor". {file} is replaced '
              'with the path. Leave empty for the system default application.',
          below: TextField(
            controller: _editor,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            onChanged: (text) {
              appSettings.externalEditor = text.trim();
              appSettings.changed();
            },
            decoration: InputDecoration(
              isDense: true,
              hintText: 'code --goto {file}',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              suffixIcon: _editor.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Use the system default',
                      iconSize: 16,
                      onPressed: () {
                        _editor.clear();
                        appSettings.externalEditor = '';
                        appSettings.changed();
                      },
                      icon: const Icon(Icons.close),
                    ),
              helperText: _editor.text.contains('{file}') ||
                      _editor.text.trim().isEmpty
                  ? null
                  : 'Without {file}, the path is added at the end.',
              helperStyle: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}
