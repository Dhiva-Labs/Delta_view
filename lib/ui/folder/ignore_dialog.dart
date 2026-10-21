/// What a folder comparison leaves out, and a quick way to leave out more
/// for this comparison only.
library;

import 'package:flutter/material.dart';

import '../../compare/folder_format.dart';
import '../../theme.dart';

/// Shows the ignore rules in effect and the entries they left out, with a
/// field for adding patterns to this comparison. Returns the new list of
/// temporary patterns, or null when nothing changed.
Future<List<String>?> showIgnoreDialog(
  BuildContext context, {
  required List<String> settingsPatterns,
  required bool respectGitignore,
  required List<String> temporary,
  required int ignoredCount,
  required List<String> ignoredPaths,
}) =>
    showDialog<List<String>>(
      context: context,
      builder: (_) => _IgnoreDialog(
        settingsPatterns: settingsPatterns,
        respectGitignore: respectGitignore,
        temporary: temporary,
        ignoredCount: ignoredCount,
        ignoredPaths: ignoredPaths,
      ),
    );

class _IgnoreDialog extends StatefulWidget {
  const _IgnoreDialog({
    required this.settingsPatterns,
    required this.respectGitignore,
    required this.temporary,
    required this.ignoredCount,
    required this.ignoredPaths,
  });

  final List<String> settingsPatterns;
  final bool respectGitignore;
  final List<String> temporary;
  final int ignoredCount;
  final List<String> ignoredPaths;

  @override
  State<_IgnoreDialog> createState() => _IgnoreDialogState();
}

class _IgnoreDialogState extends State<_IgnoreDialog> {
  late final List<String> _temporary = List.of(widget.temporary);
  final _field = TextEditingController();
  final _fieldFocus = FocusNode();

  bool get _changed =>
      _temporary.length != widget.temporary.length ||
      Iterable.generate(_temporary.length)
          .any((i) => _temporary[i] != widget.temporary[i]);

  @override
  void dispose() {
    _field.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// Enter adds the typed pattern; Enter again on the empty field applies.
  void _add() {
    final pattern = _field.text.trim();
    if (pattern.isEmpty) {
      if (_changed) Navigator.pop(context, _temporary);
      return;
    }
    setState(() {
      if (!_temporary.contains(pattern)) _temporary.add(pattern);
      _field.clear();
    });
    _fieldFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The scan lists only the first few hundred ignored paths.
    final unlisted = widget.ignoredCount - widget.ignoredPaths.length;
    final labelStyle = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant);

    Widget patternChip(String pattern, {VoidCallback? onRemove}) => Chip(
          label: Text(pattern,
              style: monoStyle.copyWith(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
          visualDensity: VisualDensity.compact,
          onDeleted: onRemove,
          deleteButtonTooltipMessage: 'Stop ignoring',
        );

    return AlertDialog(
      title: const Text('Ignored entries'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _field,
                focusNode: _fieldFocus,
                autofocus: true,
                style: monoStyle.copyWith(fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Also ignore in this comparison',
                  hintText: 'e.g. *.log, dist/, /docs/drafts',
                  helperText:
                      'Gitignore syntax. A name matches at any depth; a path '
                      'with / is relative to the compared folders.',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  suffixIcon: IconButton(
                    tooltip: 'Add',
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                  ),
                ),
                onSubmitted: (_) => _add(),
              ),
              if (_temporary.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('This comparison', style: labelStyle),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final pattern in _temporary)
                    patternChip(pattern,
                        onRemove: () =>
                            setState(() => _temporary.remove(pattern))),
                ]),
              ],
              const SizedBox(height: 14),
              Text('From settings', style: labelStyle),
              const SizedBox(height: 6),
              if (widget.settingsPatterns.isEmpty)
                Text('No patterns.',
                    style: TextStyle(color: scheme.onSurfaceVariant))
              else
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final pattern in widget.settingsPatterns)
                    patternChip(pattern),
                ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(
                    widget.respectGitignore
                        ? Icons.check_circle_outline
                        : Icons.do_not_disturb_on_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                    widget.respectGitignore
                        ? '.gitignore files on both sides are followed.'
                        : '.gitignore files are not followed.',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 16),
              Text(
                  widget.ignoredCount == 0
                      ? 'Nothing was left out in the last scan.'
                      : 'Left out in the last scan '
                          '(${formatCount(widget.ignoredCount)})',
                  style: labelStyle),
              if (widget.ignoredPaths.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemExtent: 22,
                    itemCount:
                        widget.ignoredPaths.length + (unlisted > 0 ? 1 : 0),
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        i < widget.ignoredPaths.length
                            ? widget.ignoredPaths[i]
                            : '… and ${formatCount(unlisted)} more',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle.copyWith(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _changed ? _temporary : null),
          child: Text(_changed ? 'Apply and rescan' : 'Done'),
        ),
      ],
    );
  }
}
