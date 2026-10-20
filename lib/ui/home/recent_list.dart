/// Recent comparisons on the home screen, from [AppSettings.recents].
library;

import 'package:flutter/material.dart';

import '../../cli/user_paths.dart';
import '../../compare/comparison.dart';
import '../../settings/app_settings.dart';
import '../comparison_view.dart';
import 'relative_time.dart';

class RecentList extends StatelessWidget {
  const RecentList({super.key, required this.onOpen});

  final void Function(Comparison comparison) onOpen;

  Future<void> _clearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear recent comparisons?'),
        content: const Text('Pinned entries are removed too.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear all')),
        ],
      ),
    );
    if (ok == true) {
      appSettings.recents.clear();
      appSettings.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        final recents = [
          ...appSettings.recents.where((r) => r.pinned),
          ...appSettings.recents.where((r) => !r.pinned),
        ];
        if (recents.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
              child: Row(
                children: [
                  Text('Recent',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _clearAll(context),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.7)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < recents.length; i++) ...[
                    if (i > 0)
                      Divider(
                          height: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.4)),
                    _RecentRow(entry: recents[i], onOpen: onOpen),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({required this.entry, required this.onOpen});

  final RecentComparison entry;
  final void Function(Comparison comparison) onOpen;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hovered = false;

  void _remove() {
    appSettings.recents.remove(widget.entry);
    appSettings.changed();
  }

  void _togglePin() {
    widget.entry.pinned = !widget.entry.pinned;
    appSettings.changed();
  }

  void _open() {
    final comparison = Comparison.fromJson(widget.entry.comparison);
    if (comparison == null) {
      // An entry written by a newer version, or corrupt: drop it.
      _remove();
      return;
    }
    widget.onOpen(comparison);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final comparison = Comparison.fromJson(widget.entry.comparison);
    final available = comparison == null || _localPathsExist(comparison);
    final pinned = widget.entry.pinned;

    final (title, subtitle) = _describe(comparison);
    final icon = comparison == null
        ? Icons.help_outline
        : comparisonIcon(comparison);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: _open,
        child: Tooltip(
          message: _fullDescription(comparison),
          waitDuration: const Duration(milliseconds: 700),
          child: Container(
          color: _hovered
              ? scheme.surfaceContainerHigh.withValues(alpha: 0.5)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Opacity(
            opacity: available ? 1 : 0.5,
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 19, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        available ? subtitle : '$subtitle · no longer exists',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(relativeTime(widget.entry.lastOpened),
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 4),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hovered || pinned ? 1 : 0,
                  child: IconButton(
                    tooltip: pinned ? 'Unpin' : 'Pin to the top',
                    iconSize: 17,
                    visualDensity: VisualDensity.compact,
                    onPressed: _togglePin,
                    icon: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      color: pinned ? scheme.primary : null,
                    ),
                  ),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hovered ? 1 : 0,
                  child: IconButton(
                    tooltip: 'Remove from recent',
                    iconSize: 17,
                    visualDensity: VisualDensity.compact,
                    onPressed: _remove,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  /// Every side on its own line, for the tooltip (the row itself cuts
  /// long paths short).
  String _fullDescription(Comparison? c) => switch (c) {
        null => 'This entry could not be read.',
        FolderComparison c => '${c.left.description}\n${c.right.description}',
        FileComparison c => '${c.left.description}\n${c.right.description}',
        TextComparison _ => 'Pasted text',
        ThreeWayComparison c => [
            c.left.description,
            c.base.description,
            c.right.description,
            if (c.output != null) '→ ${c.output!.description}',
          ].join('\n'),
      };

  (String, String) _describe(Comparison? c) => switch (c) {
        null => ('Unreadable entry', 'Click to remove'),
        FolderComparison c => (
            c.title,
            '${_where(c.left)}  →  ${_where(c.right)}'
          ),
        FileComparison c => (
            c.title,
            '${_where(c.left)}  →  ${_where(c.right)}'
          ),
        TextComparison c => (c.title, 'Pasted text'),
        ThreeWayComparison c => (
            c.title,
            '${c.left.label} · ${c.base.label} · ${c.right.label}'
          ),
      };

  String _where(SourceSpec spec) => switch (spec) {
        LocalSource s => abbreviateHome(s.path),
        _ => spec.description,
      };
}

bool _localPathsExist(Comparison c) {
  final specs = switch (c) {
    FolderComparison c => [c.left, c.right],
    FileComparison c => [c.left, c.right],
    TextComparison _ => <SourceSpec>[],
    ThreeWayComparison c => [c.left, c.base, c.right],
  };
  for (final spec in specs) {
    final path = switch (spec) {
      LocalSource s => s.path,
      ArchiveSource s => s.archivePath,
      _ => null,
    };
    if (path != null && pathKindOf(path) == PathKind.missing) return false;
  }
  return true;
}
