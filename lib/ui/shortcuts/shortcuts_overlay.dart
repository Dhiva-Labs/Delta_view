/// The keyboard shortcut overlay (Ctrl+/): every action by group with its
/// current key, in as many columns as the window has room for.
library;

import 'package:flutter/material.dart';

import 'app_shortcuts.dart';
import 'key_caps.dart';

/// Shows the overlay. [onOpenSettings] takes the user to the Keyboard
/// section to rebind keys.
Future<void> showShortcutsOverlay(BuildContext context,
    {VoidCallback? onOpenSettings}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) => _ShortcutsDialog(onOpenSettings: onOpenSettings),
  );
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog({this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: scheme.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1080,
          maxHeight: size.height - 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 6),
              child: Row(
                children: [
                  Icon(Icons.keyboard_outlined, color: scheme.primary),
                  const SizedBox(width: 12),
                  Text('Keyboard shortcuts',
                      style: textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (onOpenSettings != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        onOpenSettings!();
                      },
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Change keys'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 900
                        ? 3
                        : constraints.maxWidth >= 600
                            ? 2
                            : 1;
                    return _GroupColumns(columns: columns);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lays the groups out in [columns] masonry-style columns so a long group
/// does not leave a short one floating in empty space.
class _GroupColumns extends StatelessWidget {
  const _GroupColumns({required this.columns});

  final int columns;

  @override
  Widget build(BuildContext context) {
    final groups = ShortcutGroup.values;
    final buckets = List.generate(columns, (_) => <ShortcutGroup>[]);
    final heights = List.filled(columns, 0);
    for (final group in groups) {
      var shortest = 0;
      for (var i = 1; i < columns; i++) {
        if (heights[i] < heights[shortest]) shortest = i;
      }
      buckets[shortest].add(group);
      heights[shortest] += AppAction.inGroup(group).length + 3;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < columns; i++) ...[
          if (i > 0) const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: [
                for (final group in buckets[i])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _GroupCard(group: group),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});

  final ShortcutGroup group;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = AppAction.inGroup(group);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          for (final action in actions)
            _ShortcutRow(label: action.label, keys: action.keyLabel),
          if (group == ShortcutGroup.tabs)
            const _ShortcutRow(label: 'Go to tab 1 to 9', keys: tabNumberKeyLabel),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.label, required this.keys});

  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          KeyCaps(keys),
        ],
      ),
    );
  }
}
