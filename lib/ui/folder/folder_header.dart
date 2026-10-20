/// The parts of the folder view above the tree: the two paths, the change
/// summary, and the scanning / error states that replace the tree.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../compare/folder_compare.dart';
import '../../compare/folder_format.dart';
import '../../theme.dart';
import 'tree_rows.dart' show statusIcon;

/// One side's location. The name comes first so it stays readable when a
/// long path has to be cut short.
class PathChip extends StatelessWidget {
  const PathChip({
    super.key,
    required this.label,
    required this.path,
    this.readOnly = false,
  });

  final String label;
  final String path;

  /// Shows a lock: this side cannot be changed (an archive, say).
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: readOnly ? '$path (read-only)' : path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (readOnly) ...[
              Icon(Icons.lock_outline,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: label,
                    style: TextStyle(
                        fontWeight: FontWeight.w600, color: scheme.onSurface),
                  ),
                  if (path != label) TextSpan(text: '   $path'),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prominent change summary shown at the top of the comparison result.
/// Its icons double as the legend for the status column of the tree.
class StatsHeader extends StatelessWidget {
  const StatsHeader({super.key, required this.root, required this.palette});

  final CompareNode root;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget card(EntryStatus status, int count, String label, Color color) {
      return Expanded(
        child: Semantics(
          label: '$count $label',
          excludeSemantics: true,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(statusIcon(status), size: 17, color: color),
                const SizedBox(width: 8),
                Text(formatCount(count),
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: color)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          card(EntryStatus.modified, root.modifiedCount, 'modified',
              palette.modified),
          card(EntryStatus.onlyLeft, root.onlyLeftCount, 'left only',
              palette.removed),
          card(EntryStatus.onlyRight, root.onlyRightCount, 'right only',
              palette.added),
          card(EntryStatus.identical, root.identicalCount, 'identical',
              scheme.outline),
        ],
      ),
    );
  }
}

/// `1,234 files · 0:07 · src/lib/main.dart`, refreshed every second even
/// when a single large file holds the scan up.
class ScanProgressLine extends StatefulWidget {
  const ScanProgressLine({
    super.key,
    required this.progress,
    required this.started,
    this.style,
    this.textAlign,
  });

  final ValueListenable<ScanProgress?> progress;
  final DateTime started;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  State<ScanProgressLine> createState() => _ScanProgressLineState();
}

class _ScanProgressLineState extends State<ScanProgressLine> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
        const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ScanProgress?>(
      valueListenable: widget.progress,
      builder: (context, progress, _) {
        final elapsed =
            formatElapsed(DateTime.now().difference(widget.started));
        final text = progress == null
            ? elapsed
            : '${formatCount(progress.filesCompared)} files · $elapsed · '
                '${progress.currentPath}';
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: widget.textAlign,
          style: widget.style,
        );
      },
    );
  }
}

/// Shown in place of the tree during the first scan.
class ScanningView extends StatelessWidget {
  const ScanningView({
    super.key,
    required this.progress,
    required this.started,
    required this.onCancel,
  });

  final ValueListenable<ScanProgress?> progress;
  final DateTime started;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 44, height: 44, child: CircularProgressIndicator()),
            const SizedBox(height: 20),
            Text('Scanning folders…',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ScanProgressLine(
                progress: progress,
                started: started,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floats over the tree while it is being rescanned, so the old results
/// stay readable (and selected) in the meantime and nothing shifts.
class RescanToast extends StatelessWidget {
  const RescanToast({
    super.key,
    required this.progress,
    required this.started,
    required this.onCancel,
  });

  final ValueListenable<ScanProgress?> progress;
  final DateTime started;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Rescanning',
                  style: style.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Flexible(
                child: ScanProgressLine(
                    progress: progress, started: started, style: style),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the tree when there is nothing to show: the scan
/// failed, was cancelled, or this kind of source is not available yet.
class ScanMessageView extends StatelessWidget {
  const ScanMessageView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.error = false,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? message;
  final bool error;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 42,
                color: error ? scheme.error : scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Text(message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: actions),
          ],
        ),
      ),
    );
  }
}
