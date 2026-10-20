import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../settings/app_settings.dart';
import 'diff_preview.dart';
import 'settings_widgets.dart';

const accentSwatches = <(String, Color)>[
  ('Indigo', Color(0xFF6366F1)),
  ('Blue', Color(0xFF2563EB)),
  ('Sky', Color(0xFF0EA5E9)),
  ('Teal', Color(0xFF0D9488)),
  ('Green', Color(0xFF16A34A)),
  ('Amber', Color(0xFFD97706)),
  ('Orange', Color(0xFFEA580C)),
  ('Rose', Color(0xFFE11D48)),
  ('Pink', Color(0xFFDB2777)),
  ('Purple', Color(0xFF9333EA)),
  ('Slate', Color(0xFF475569)),
];

class AppearanceSection extends StatefulWidget {
  const AppearanceSection({super.key});

  @override
  State<AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<AppearanceSection> {
  late final _hex = TextEditingController(text: _hexOf(appSettings.accentColor));
  final _hexFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() {
      // Snap the field back to the real colour when the user leaves it
      // with a half-typed value.
      if (!_hexFocus.hasFocus) _hex.text = _hexOf(appSettings.accentColor);
    });
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  void _setAccent(Color color) {
    appSettings.accentColor = color;
    appSettings.changed();
    if (!_hexFocus.hasFocus) _hex.text = _hexOf(color);
  }

  void _hexChanged(String text) {
    final clean = text.replaceAll('#', '').trim();
    if (clean.length != 6) return;
    final value = int.tryParse(clean, radix: 16);
    if (value == null) return;
    _setAccent(Color(0xFF000000 | value));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsSection(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      children: [
        SegmentRow<ThemeMode>(
          label: 'Theme',
          description: 'System follows the desktop setting.',
          value: appSettings.themeMode,
          options: const [
            (ThemeMode.system, 'System', Icons.brightness_auto_outlined),
            (ThemeMode.light, 'Light', Icons.light_mode_outlined),
            (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
          ],
          onChanged: (mode) {
            appSettings.themeMode = mode;
            appSettings.changed();
          },
        ),
        SettingRow(
          label: 'Accent colour',
          description: 'Seeds the whole colour scheme.',
          below: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (name, color) in accentSwatches)
                _Swatch(
                  name: name,
                  color: color,
                  selected: appSettings.accentColor.toARGB32() ==
                      color.toARGB32(),
                  onTap: () => _setAccent(color),
                ),
              SizedBox(
                width: 132,
                child: TextField(
                  controller: _hex,
                  focusNode: _hexFocus,
                  maxLength: 6,
                  style: const TextStyle(fontSize: 13),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                  ],
                  onChanged: _hexChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    prefixText: '#',
                    hintText: 'RRGGBB',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 9),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: appSettings.accentColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                      ),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 34, minHeight: 0),
                  ),
                ),
              ),
            ],
          ),
        ),
        SettingRow(
          label: 'Diff colours',
          description: 'How added, removed and changed lines are marked.',
          below: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 620 ? 3 : 1;
              final cards = [
                for (final preset in DiffColorPreset.values)
                  _PresetCard(
                    preset: preset,
                    selected: appSettings.diffColors == preset,
                    onTap: () {
                      appSettings.diffColors = preset;
                      appSettings.changed();
                    },
                  ),
              ];
              if (columns == 1) {
                return Column(children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    cards[i],
                  ],
                ]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: cards[i]),
                  ],
                ],
              );
            },
          ),
        ),
        SegmentRow<UiDensity>(
          label: 'Density',
          description: 'How much room controls take.',
          value: appSettings.density,
          options: const [
            (UiDensity.comfortable, 'Comfortable', null),
            (UiDensity.compact, 'Compact', null),
          ],
          onChanged: (density) {
            appSettings.density = density;
            appSettings.changed();
          },
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              width: selected ? 2.5 : 1,
              color: selected ? scheme.onSurface : Colors.black12,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final DiffColorPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (title, blurb) = switch (preset) {
      DiffColorPreset.classic => ('Classic', 'Green, red and amber.'),
      DiffColorPreset.colorBlindSafe => (
          'Colour-blind safe',
          'Blue, orange and purple: readable with red–green colour blindness.'
        ),
      DiffColorPreset.highContrast => (
          'High contrast',
          'Stronger fills for bright rooms and low-contrast screens.'
        ),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.25)
              : Colors.transparent,
          border: Border.all(
            width: selected ? 2 : 1,
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 16,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(blurb,
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            DiffPreview(preset: preset),
          ],
        ),
      ),
    );
  }
}
