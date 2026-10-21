import 'package:flutter/material.dart';

import '../../diff/compare_options.dart';
import '../../settings/app_settings.dart';
import 'settings_widgets.dart';

class RulesSection extends StatelessWidget {
  const RulesSection({super.key});

  void _update(CompareOptions options) {
    appSettings.compareOptions = options;
    appSettings.changed();
  }

  @override
  Widget build(BuildContext context) {
    final options = appSettings.compareOptions;
    return SettingsSection(
      title: 'Comparison rules',
      icon: Icons.rule,
      description: 'Which differences count. Applied to new comparisons.',
      children: [
        ChoiceRow<WhitespaceMode>(
          label: 'Whitespace',
          description: 'Spaces and tabs inside lines.',
          value: options.whitespace,
          width: 230,
          options: const [
            (WhitespaceMode.exact, 'Every character matters'),
            (WhitespaceMode.trailing, 'Ignore trailing whitespace'),
            (WhitespaceMode.changes, 'Ignore changes in amount'),
            (WhitespaceMode.all, 'Ignore all whitespace'),
          ],
          onChanged: (mode) => _update(options.copyWith(whitespace: mode)),
        ),
        SwitchRow(
          label: 'Ignore case',
          description: '"Hello" and "hello" compare equal.',
          value: options.ignoreCase,
          onChanged: (v) => _update(options.copyWith(ignoreCase: v)),
        ),
        SwitchRow(
          label: 'Ignore line endings',
          description: 'CRLF (Windows) and LF (Unix) compare equal.',
          value: options.ignoreLineEndings,
          onChanged: (v) => _update(options.copyWith(ignoreLineEndings: v)),
        ),
        SwitchRow(
          label: 'Ignore blank lines',
          description: 'Empty lines are left out of the comparison.',
          value: options.ignoreBlankLines,
          onChanged: (v) => _update(options.copyWith(ignoreBlankLines: v)),
        ),
      ],
    );
  }
}
