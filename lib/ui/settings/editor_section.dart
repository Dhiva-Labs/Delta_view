import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../theme.dart';
import 'settings_widgets.dart';

const monospaceFonts = [
  'monospace',
  'JetBrains Mono',
  'Fira Code',
  'Cascadia Code',
  'Source Code Pro',
  'DejaVu Sans Mono',
  'Ubuntu Mono',
  'Liberation Mono',
  'Consolas',
  'Menlo',
  'SF Mono',
  'Courier New',
];

const _custom = '__custom__';

class EditorSection extends StatefulWidget {
  const EditorSection({super.key});

  @override
  State<EditorSection> createState() => _EditorSectionState();
}

class _EditorSectionState extends State<EditorSection> {
  // Sliders show their live value while dragging; the setting is written
  // when the drag ends.
  double? _draggingSize;
  double? _draggingLineHeight;

  late bool _customFont = !monospaceFonts.contains(appSettings.editorFontFamily);
  late final _customFontField =
      TextEditingController(text: _customFont ? appSettings.editorFontFamily : '');

  @override
  void dispose() {
    _customFontField.dispose();
    super.dispose();
  }

  void _save() => appSettings.changed();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fontSize = _draggingSize ?? appSettings.editorFontSize;
    final lineHeight = _draggingLineHeight ?? appSettings.editorLineHeight;
    final previewStyle = editorTextStyle().copyWith(
      fontSize: fontSize,
      height: lineHeight,
    );

    return SettingsSection(
      title: 'Editor',
      icon: Icons.code,
      description: 'The text in file and text comparisons.',
      children: [
        ChoiceRow<String>(
          label: 'Font',
          description: 'Any monospace font installed on this computer.',
          value: _customFont ? _custom : appSettings.editorFontFamily,
          width: 220,
          options: [
            for (final font in monospaceFonts)
              (font, font == 'monospace' ? 'System monospace' : font),
            (_custom, 'Custom…'),
          ],
          onChanged: (value) {
            setState(() {
              _customFont = value == _custom;
              if (!_customFont) {
                appSettings.editorFontFamily = value;
                _save();
              } else if (_customFontField.text.trim().isNotEmpty) {
                appSettings.editorFontFamily = _customFontField.text.trim();
                _save();
              }
            });
          },
        ),
        if (_customFont)
          SettingRow(
            label: 'Custom font family',
            control: SizedBox(
              width: 220,
              child: TextField(
                controller: _customFontField,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'e.g. Iosevka',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onChanged: (text) {
                  final name = text.trim();
                  if (name.isEmpty) return;
                  appSettings.editorFontFamily = name;
                  _save();
                },
              ),
            ),
          ),
        SliderRow(
          label: 'Font size',
          value: fontSize,
          min: 8,
          max: 32,
          divisions: 24,
          display: '${fontSize.round()} px',
          onChanged: (v) => setState(() => _draggingSize = v),
          onChangeEnd: (v) {
            setState(() => _draggingSize = null);
            appSettings.editorFontSize = v.roundToDouble();
            _save();
          },
        ),
        SliderRow(
          label: 'Line height',
          value: lineHeight,
          min: 1.0,
          max: 2.5,
          divisions: 30,
          display: lineHeight.toStringAsFixed(2),
          onChanged: (v) => setState(() => _draggingLineHeight = v),
          onChangeEnd: (v) {
            setState(() => _draggingLineHeight = null);
            appSettings.editorLineHeight = (v * 20).round() / 20;
            _save();
          },
        ),
        SettingRow(
          label: 'Preview',
          below: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Text(
              'final total = items.fold(0, (sum, item) => sum + item.size);\n'
              'if (total > limit) throw StateError("too big: \$total");',
              style: previewStyle,
            ),
          ),
        ),
        StepperRow(
          label: 'Tab width',
          description: 'Spaces a tab character takes up.',
          value: appSettings.tabWidth,
          min: 1,
          max: 16,
          onChanged: (v) {
            appSettings.tabWidth = v;
            _save();
          },
        ),
        SwitchRow(
          label: 'Show whitespace',
          description: 'Mark spaces and tabs with faint symbols.',
          value: appSettings.showWhitespace,
          onChanged: (v) {
            appSettings.showWhitespace = v;
            _save();
          },
        ),
        SwitchRow(
          label: 'Wrap long lines',
          value: appSettings.wordWrap,
          onChanged: (v) {
            appSettings.wordWrap = v;
            _save();
          },
        ),
        SwitchRow(
          label: 'Syntax highlighting',
          value: appSettings.syntaxHighlighting,
          onChanged: (v) {
            appSettings.syntaxHighlighting = v;
            _save();
          },
        ),
        SwitchRow(
          label: 'Fold unchanged lines',
          description: 'Collapse long runs of identical lines.',
          value: appSettings.foldUnchanged,
          onChanged: (v) {
            appSettings.foldUnchanged = v;
            _save();
          },
        ),
        StepperRow(
          label: 'Context lines',
          description: 'Unchanged lines kept around each change when folding.',
          value: appSettings.foldContext,
          min: 0,
          max: 50,
          enabled: appSettings.foldUnchanged,
          onChanged: (v) {
            appSettings.foldContext = v;
            _save();
          },
        ),
      ],
    );
  }
}
