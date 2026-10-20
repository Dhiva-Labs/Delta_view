import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../theme.dart';

/// A four-line mock diff in the colours of [preset], for the settings page.
class DiffPreview extends StatelessWidget {
  const DiffPreview({super.key, required this.preset});

  final DiffColorPreset preset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.preset(preset, Theme.of(context).brightness);
    final style =
        editorTextStyle(context).copyWith(fontSize: 11.5, height: 1.4);
    final muted = style.copyWith(color: scheme.onSurfaceVariant);

    Widget row(Color background, Color? gutter, String sign,
        List<InlineSpan> spans) {
      return Container(
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              child: Text(sign,
                  style: style.copyWith(
                      color: gutter ?? scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: Text.rich(TextSpan(style: style, children: spans),
                  maxLines: 1, overflow: TextOverflow.clip),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row(Colors.transparent, null, ' ', [
                  TextSpan(text: 'total = 0', style: muted),
                ]),
                row(palette.removedBg, palette.removed, '−', [
                  const TextSpan(text: 'for item in '),
                  TextSpan(
                      text: 'list',
                      style: TextStyle(backgroundColor: palette.removedEmphasis)),
                ]),
                row(palette.addedBg, palette.added, '+', [
                  const TextSpan(text: 'for item in '),
                  TextSpan(
                      text: 'items',
                      style: TextStyle(backgroundColor: palette.addedEmphasis)),
                ]),
                row(palette.modifiedBg, palette.modified, '~', [
                  const TextSpan(text: 'total += item.size'),
                ]),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 6),
            color: scheme.surfaceContainerLow,
            child: Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                _dot(palette.added, 'added', scheme),
                _dot(palette.removed, 'removed', scheme),
                _dot(palette.modified, 'modified', scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color, String label, ColorScheme scheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
