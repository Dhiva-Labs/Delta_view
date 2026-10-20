import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../shortcuts/app_shortcuts.dart';
import '../shortcuts/key_caps.dart';
import '../shortcuts/key_recorder.dart';
import 'settings_widgets.dart';

class KeyboardSection extends StatefulWidget {
  const KeyboardSection({super.key});

  @override
  State<KeyboardSection> createState() => _KeyboardSectionState();
}

class _KeyboardSectionState extends State<KeyboardSection> {
  AppAction? _recording;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final anyRebound = appSettings.shortcutOverrides.isNotEmpty;
    return SettingsSection(
      title: 'Keyboard',
      icon: Icons.keyboard_outlined,
      description: 'Click a shortcut, then press the keys you want.',
      trailing: TextButton.icon(
        onPressed: anyRebound ? resetAllShortcuts : null,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: const Text('Reset all'),
      ),
      children: [
        for (final group in ShortcutGroup.values)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
                padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
                child: Text(
                  group.label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final action in AppAction.inGroup(group))
                _ActionRow(
                  action: action,
                  recording: _recording == action,
                  onStart: () => setState(() => _recording = action),
                  onStop: () => setState(() => _recording = null),
                ),
              if (group == ShortcutGroup.tabs)
                const SettingRow(
                  label: 'Go to tab 1 to 9',
                  description: 'Always available.',
                  control: KeyCaps(tabNumberKeyLabel),
                ),
            ],
          ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.recording,
    required this.onStart,
    required this.onStop,
  });

  final AppAction action;
  final bool recording;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final conflicts = conflictingActions(action);
    final rebound = action.isRebound;

    Widget keys = KeyCaps(action.keyLabel, emphasized: recording);
    if (recording) {
      keys = ShortcutRecorder(
        onRecorded: (activator) {
          rebindAction(action, activator);
          onStop();
        },
        onCancel: onStop,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Press keys… ',
                style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: scheme.primary)),
            keys,
          ],
        ),
      );
    }

    return InkWell(
      onTap: recording ? null : onStart,
      child: Container(
        color: recording
            ? scheme.primaryContainer.withValues(alpha: 0.18)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(action.label, style: const TextStyle(fontSize: 13.5)),
                  if (conflicts.isNotEmpty && !recording)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 14, color: scheme.error),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Also used by ${conflicts.map((a) => a.label).join(', ')}',
                              style: TextStyle(
                                  fontSize: 11.5, color: scheme.error),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            keys,
            SizedBox(
              width: 36,
              child: rebound && !recording
                  ? IconButton(
                      tooltip: 'Reset to ${describeActivator(action.defaultActivator)}',
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => rebindAction(action, null),
                      icon: const Icon(Icons.restart_alt),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
