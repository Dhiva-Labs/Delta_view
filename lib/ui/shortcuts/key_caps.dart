import 'package:flutter/material.dart';

/// `Ctrl+Shift+V` drawn as a row of small keycaps, for the shortcut
/// overlay and the settings page.
class KeyCaps extends StatelessWidget {
  const KeyCaps(this.label, {super.key, this.emphasized = false});

  /// A `+`-joined key description from `describeActivator`.
  final String label;

  /// Highlighted (e.g. while recording a new key).
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // '+' is both the separator and a key label ("Ctrl++"): split on the
    // separator but keep an empty trailing part as a literal plus.
    final parts = label.split('+');
    final keys = <String>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty && i == parts.length - 1) {
        if (keys.isNotEmpty && keys.last.isEmpty) keys.removeLast();
        keys.add('+');
      } else if (parts[i].isNotEmpty) {
        keys.add(parts[i]);
      }
    }
    final background = emphasized
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    final border = emphasized
        ? scheme.primary.withValues(alpha: 0.6)
        : scheme.outlineVariant.withValues(alpha: 0.8);
    final text = emphasized ? scheme.onPrimaryContainer : scheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text('+',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
          Container(
            constraints: const BoxConstraints(minWidth: 24),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.12),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Text(
              keys[i],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: text,
                height: 1.3,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
