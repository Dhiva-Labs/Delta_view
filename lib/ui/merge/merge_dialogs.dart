/// The questions the merge view asks: where to save, whether to save with
/// conflicts left, and what to do with unsaved work on close.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../compare/comparison.dart';
import '../../compare/diff_side.dart';

/// Asks where to write a merge that has no output file: over the base,
/// left or right file, or to a new file. Sides that cannot be written (in
/// an archive, say) are shown but disabled. Null when cancelled.
Future<SourceSpec?> askSaveTarget(
  BuildContext context,
  ThreeWayComparison comparison,
) async {
  final sides = [
    ('Base', Icons.call_merge, comparison.base),
    ('Left', Icons.west, comparison.left),
    ('Right', Icons.east, comparison.right),
  ];
  final writable = await Future.wait([
    for (final (_, _, spec) in sides)
      DiffSide.source(spec).canWrite().catchError((_) => false),
  ]);
  if (!context.mounted) return null;

  final choice = await showDialog<Object>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: const Text('Where should the merge go?'),
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < sides.length; i++)
                ListTile(
                  enabled: writable[i],
                  leading: Icon(sides[i].$2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  title: Text(
                    'Overwrite ${sides[i].$1.toLowerCase()}'
                    ' · ${sides[i].$3.label}',
                  ),
                  subtitle: Text(
                    writable[i]
                        ? sides[i].$3.description
                        : '${sides[i].$3.description} (read-only)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, sides[i].$3),
                ),
              ListTile(
                leading: const Icon(Icons.save_as_outlined),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                title: const Text('Save as a new file…'),
                onTap: () => Navigator.pop(context, #saveAs),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
  if (choice is SourceSpec) return choice;
  if (choice == #saveAs) return pickSaveAsTarget(comparison);
  return null;
}

/// A file dialog for "Save as", starting next to the base file when it is
/// on this machine.
Future<SourceSpec?> pickSaveAsTarget(ThreeWayComparison comparison) async {
  final base = comparison.base;
  final location = await getSaveLocation(
    suggestedName: base.label,
    initialDirectory: base is LocalSource ? p.dirname(base.path) : null,
    confirmButtonText: 'Save merge',
  );
  return location == null ? null : LocalSource(location.path);
}

/// Confirms saving while [count] conflicts are unresolved.
Future<bool> confirmSaveWithConflicts(BuildContext context, int count) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Theme.of(context).colorScheme.error,
      ),
      title: Text(
        count == 1
            ? '1 conflict is not resolved'
            : '$count conflicts are not resolved',
      ),
      content: const SizedBox(
        width: 420,
        child: Text(
          'Unresolved conflicts are saved with conflict markers '
          '(<<<<<<< … >>>>>>>) around both versions, so nothing is lost '
          'and tools like git still see them as conflicts.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep merging'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save with markers'),
        ),
      ],
    ),
  );
  return result ?? false;
}

enum UnsavedChoice { save, discard }

/// Asks what to do with an unsaved merge before closing or leaving it.
/// Null means cancel: keep the merge open.
Future<UnsavedChoice?> askUnsavedMerge(BuildContext context, String name) {
  return showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save the merge?'),
      content: SizedBox(
        width: 420,
        child: Text(
          'The merge of $name has not been saved. Closing it '
          'without saving loses your resolutions.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: const Text('Close without saving'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Confirms throwing away unsaved resolutions to reload from disk.
Future<bool> confirmReload(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reload the files?'),
      content: const SizedBox(
        width: 400,
        child: Text(
          'Reloading merges the files on disk again and throws '
          'away the resolutions you have not saved.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Reload'),
        ),
      ],
    ),
  );
  return result ?? false;
}
