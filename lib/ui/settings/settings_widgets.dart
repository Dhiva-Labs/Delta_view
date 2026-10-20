/// Building blocks shared by the settings sections: a titled card of rows,
/// and rows with a label, an optional description and a control.
library;

import 'package:flutter/material.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.description,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  if (description != null)
                    Text(description!,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.4)),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Label and description on the left, the control on the right, and an
/// optional full-width [below] (a preview, a list editor).
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    this.description,
    this.control,
    this.below,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final String? description;
  final Widget? control;
  final Widget? below;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: enabled
                                ? scheme.onSurface
                                : scheme.onSurface.withValues(alpha: 0.45))),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(description!,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: enabled
                                  ? scheme.onSurfaceVariant
                                  : scheme.onSurfaceVariant
                                      .withValues(alpha: 0.5))),
                    ],
                  ],
                ),
              ),
              if (control != null) ...[
                const SizedBox(width: 16),
                control!,
              ],
            ],
          ),
          if (below != null) ...[
            const SizedBox(height: 12),
            below!,
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(onTap: enabled ? onTap : null, child: body);
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      label: label,
      description: description,
      enabled: enabled,
      onTap: () => onChanged(!value),
      control: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

/// A dropdown of labelled values.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 200,
  });

  final String label;
  final String? description;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      label: label,
      description: description,
      control: SizedBox(
        width: width,
        child: DropdownMenu<T>(
          initialSelection: value,
          expandedInsets: EdgeInsets.zero,
          inputDecorationTheme: const InputDecorationTheme(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10))),
          ),
          textStyle: const TextStyle(fontSize: 13),
          dropdownMenuEntries: [
            for (final (v, text) in options)
              DropdownMenuEntry(value: v, label: text),
          ],
          onSelected: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// A row of segments for a small set of choices.
class SegmentRow<T> extends StatelessWidget {
  const SegmentRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.options,
    required this.onChanged,
    this.below,
  });

  final String label;
  final String? description;
  final T value;
  final List<(T, String, IconData?)> options;
  final ValueChanged<T> onChanged;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      label: label,
      description: description,
      below: below,
      control: SegmentedButton<T>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 12.5),
        ),
        segments: [
          for (final (v, text, icon) in options)
            ButtonSegment(
              value: v,
              label: Text(text),
              icon: icon == null ? null : Icon(icon, size: 16),
            ),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// `[−] 4 [+]` for small integers.
class StepperRow extends StatelessWidget {
  const StepperRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.enabled = true,
    this.format,
  });

  final String label;
  final String? description;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final String Function(int)? format;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingRow(
      label: label,
      description: description,
      enabled: enabled,
      control: Container(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed:
                  enabled && value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 36,
              child: Text(
                format?.call(value) ?? '$value',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed:
                  enabled && value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slider that reports continuously through [onChanged] and once more
/// through [onChangeEnd] when released, so the settings file (and the
/// whole app) are not rewritten on every pixel of a drag.
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.display,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final String? description;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingRow(
      label: label,
      description: description,
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 200,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(display,
                textAlign: TextAlign.end,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
