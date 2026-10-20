/// Dialogs for changing the compared folders: choosing a synchronization,
/// reviewing every step of a plan before it runs, and following it as it
/// runs.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../compare/folder_compare.dart';
import '../../compare/folder_format.dart';
import '../../compare/folder_sync.dart';
import '../../theme.dart';

/// Asks how to synchronize and returns the plan the user confirmed, or
/// null when cancelled.
Future<SyncPlan?> showSyncDialog(
  BuildContext context, {
  required CompareNode root,
  required List<CompareNode> selection,
  required bool leftWritable,
  required bool rightWritable,
  required String leftLabel,
  required String rightLabel,
}) =>
    showDialog<SyncPlan>(
      context: context,
      builder: (_) => _SyncDialog(
        root: root,
        selection: selection,
        leftWritable: leftWritable,
        rightWritable: rightWritable,
        leftLabel: leftLabel,
        rightLabel: rightLabel,
      ),
    );

class _SyncDialog extends StatefulWidget {
  const _SyncDialog({
    required this.root,
    required this.selection,
    required this.leftWritable,
    required this.rightWritable,
    required this.leftLabel,
    required this.rightLabel,
  });

  final CompareNode root;
  final List<CompareNode> selection;
  final bool leftWritable;
  final bool rightWritable;
  final String leftLabel;
  final String rightLabel;

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  late SyncMode? _mode = _firstAllowed();
  bool _selectionOnly = false;
  bool _confirmed = false;
  SyncPlan? _plan;

  bool _allowed(SyncMode mode) => switch (mode) {
        SyncMode.mirrorLeftToRight => widget.rightWritable,
        SyncMode.mirrorRightToLeft => widget.leftWritable,
        SyncMode.twoWay => widget.leftWritable && widget.rightWritable,
      };

  SyncMode? _firstAllowed() =>
      SyncMode.values.where(_allowed).firstOrNull;

  SyncPlan? get plan {
    final mode = _mode;
    if (mode == null) return null;
    return _plan ??= planSync(widget.root, mode,
        only: _selectionOnly ? widget.selection : null);
  }

  void _update(VoidCallback change) => setState(() {
        change();
        _plan = null;
        _confirmed = false;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = this.plan;
    final destructive = plan?.destructive ?? false;
    final ready = plan != null && !plan.isEmpty && (!destructive || _confirmed);

    Widget option(SyncMode mode, IconData icon, String title, String detail) {
      final allowed = _allowed(mode);
      final readOnly = switch (mode) {
        SyncMode.mirrorLeftToRight => 'The right side is read-only.',
        SyncMode.mirrorRightToLeft => 'The left side is read-only.',
        SyncMode.twoWay => 'One of the sides is read-only.',
      };
      final selected = _mode == mode;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.5)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: selected ? scheme.primary : Colors.transparent),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: allowed ? () => _update(() => _mode = mode) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
              child: Row(
                children: [
                  Radio<SyncMode>(value: mode, enabled: allowed),
                  Icon(icon,
                      size: 20,
                      color: allowed ? scheme.primary : scheme.outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: allowed ? null : scheme.outline)),
                        const SizedBox(height: 2),
                        Text(allowed ? detail : readOnly,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: const Text('Synchronize folders'),
      // Not scrollable as a whole: the list of steps shrinks instead, so
      // the confirmation below it is always in view.
      content: SizedBox(
        width: 640,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RadioGroup<SyncMode>(
                groupValue: _mode,
                onChanged: (m) {
                  if (m != null && _allowed(m)) _update(() => _mode = m);
                },
                child: Column(children: [
              option(
                SyncMode.mirrorLeftToRight,
                Icons.arrow_forward,
                'Mirror left → right',
                'Make “${widget.rightLabel}” match “${widget.leftLabel}”: '
                    'copy new and changed files, delete what exists only on '
                    'the right.',
              ),
              option(
                SyncMode.mirrorRightToLeft,
                Icons.arrow_back,
                'Mirror right → left',
                'Make “${widget.leftLabel}” match “${widget.rightLabel}”: '
                    'copy new and changed files, delete what exists only on '
                    'the left.',
              ),
              option(
                SyncMode.twoWay,
                Icons.sync_alt,
                'Two-way',
                'Copy new files both ways. Where a file differs, the newer '
                    'one wins. Nothing is deleted.',
              ),
                ]),
              ),
              if (widget.selection.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text('Apply to',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    const SizedBox(width: 12),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      segments: [
                        const ButtonSegment(
                            value: false, label: Text('Everything')),
                        ButtonSegment(
                            value: true,
                            label: Text(
                                'Selected (${widget.selection.length})')),
                      ],
                      selected: {_selectionOnly},
                      onSelectionChanged: (s) =>
                          _update(() => _selectionOnly = s.first),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              if (plan == null)
                Text('Both sides are read-only, so nothing can be changed.',
                    style: TextStyle(color: scheme.onSurfaceVariant))
              else ...[
                PlanSummary(plan: plan),
                const SizedBox(height: 10),
                Flexible(
                  child: PlanList(
                    plan: plan,
                    leftLabel: widget.leftLabel,
                    rightLabel: widget.rightLabel,
                    height: 220,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Ignored entries are left alone on both sides.',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                if (destructive) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _confirmed,
                    onChanged: (v) => setState(() => _confirmed = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(_destructiveWarning(plan),
                        style: TextStyle(
                            fontSize: 13,
                            color: scheme.error,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ],
          ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError)
              : null,
          onPressed: ready ? () => Navigator.pop(context, plan) : null,
          icon: const Icon(Icons.sync, size: 18),
          label: const Text('Synchronize'),
        ),
      ],
    );
  }
}

String _destructiveWarning(SyncPlan plan) {
  final parts = <String>[
    if (plan.overwriteCount > 0)
      '${formatCount(plan.overwriteCount)} '
          '${plan.overwriteCount == 1 ? 'file' : 'files'} will be overwritten',
    if (plan.deleteCount > 0)
      '${formatCount(plan.deletedFiles)} '
          '${plan.deletedFiles == 1 ? 'file' : 'files'} will be deleted',
  ];
  return 'I understand that ${parts.join(' and ')}. This cannot be undone.';
}

/// Counts and sizes of a plan, one chip per kind of step.
class PlanSummary extends StatelessWidget {
  const PlanSummary({super.key, required this.plan});

  final SyncPlan plan;

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (plan.isEmpty && plan.skipped.isEmpty) {
      return Text('Nothing to do: the folders already match this way.',
          style: TextStyle(color: scheme.onSurfaceVariant));
    }
    Widget chip(IconData icon, Color color, String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontSize: 12.5)),
          ]),
        );
    final copyBytes = plan.bytesFor(SyncOpKind.copy);
    final overwriteBytes = plan.bytesFor(SyncOpKind.overwrite);
    final deleteBytes = plan.bytesFor(SyncOpKind.delete);
    // Deleting folders removes more files than there are steps.
    final deletedFiles = plan.deletedFiles != plan.deleteCount
        ? ' (${formatCount(plan.deletedFiles)} files)'
        : '';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (plan.copyCount > 0)
          chip(Icons.add_circle_outline, palette.added,
              '${formatCount(plan.copyCount)} to copy · '
              '${formatSize(copyBytes)}'),
        if (plan.overwriteCount > 0)
          chip(Icons.edit_outlined, palette.modified,
              '${formatCount(plan.overwriteCount)} to overwrite · '
              '${formatSize(overwriteBytes)}'),
        if (plan.deleteCount > 0)
          chip(
              Icons.delete_outline,
              palette.removed,
              '${formatCount(plan.deleteCount)} to delete$deletedFiles'
              ' · ${formatSize(deleteBytes)}'),
        if (plan.skipped.isNotEmpty)
          chip(Icons.help_outline, scheme.outline,
              '${formatCount(plan.skipped.length)} skipped'),
      ],
    );
  }
}

/// Every step of a plan, in the order it will run.
class PlanList extends StatelessWidget {
  const PlanList({
    super.key,
    required this.plan,
    required this.leftLabel,
    required this.rightLabel,
    this.height = 240,
  });

  final SyncPlan plan;
  final String leftLabel;
  final String rightLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final count = plan.ops.length + plan.skipped.length;
    if (count == 0) return const SizedBox.shrink();

    Widget row(int index) {
      if (index >= plan.ops.length) {
        final skip = plan.skipped[index - plan.ops.length];
        return _line(
          context,
          icon: Icons.help_outline,
          color: scheme.outline,
          verb: 'Skip',
          path: skip.path,
          detail: skip.reason,
        );
      }
      final op = plan.ops[index];
      final side = op.target == Side.left ? 'left' : 'right';
      final (icon, color, verb) = switch (op.kind) {
        SyncOpKind.copy => (Icons.add_circle_outline, palette.added,
            'Copy to $side'),
        SyncOpKind.createFolder => (Icons.create_new_folder_outlined,
            palette.added, 'Create on $side'),
        SyncOpKind.overwrite => (Icons.edit_outlined, palette.modified,
            'Overwrite $side'),
        SyncOpKind.delete => (Icons.delete_outline, palette.removed,
            'Delete on $side'),
      };
      return _line(
        context,
        icon: icon,
        color: color,
        verb: verb,
        path: op.isDirectory ? '${op.path}/' : op.path,
        detail: switch (op.kind) {
          SyncOpKind.createFolder => 'empty folder',
          SyncOpKind.delete when op.isDirectory && op.files == 0 =>
            'empty folder',
          SyncOpKind.delete when op.isDirectory =>
            '${formatCount(op.files)} ${op.files == 1 ? 'file' : 'files'} · '
                '${formatSize(op.bytes)}',
          _ => formatSize(op.bytes),
        },
      );
    }

    return Container(
      constraints: BoxConstraints(maxHeight: height),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: 26,
        itemCount: count,
        itemBuilder: (context, index) => row(index),
      ),
    );
  }

  Widget _line(BuildContext context,
      {required IconData icon,
      required Color color,
      required String verb,
      required String path,
      required String detail}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 112,
            child: Text(verb,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ),
          Expanded(
            child: Text(path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle.copyWith(fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Text(detail,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Asks before running a plan made from a few entries (copy or delete
/// from the tree). Returns true to go ahead.
Future<bool> confirmPlan(
  BuildContext context, {
  required SyncPlan plan,
  required String title,
  required String confirmLabel,
  required String leftLabel,
  required String rightLabel,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlanSummary(plan: plan),
            const SizedBox(height: 10),
            Flexible(
              child: PlanList(
                  plan: plan, leftLabel: leftLabel, rightLabel: rightLabel),
            ),
            if (plan.destructive) ...[
              const SizedBox(height: 10),
              Text('This cannot be undone.',
                  style: TextStyle(
                      color: scheme.error, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: plan.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Runs [plan] behind a progress dialog that can stop it between steps.
/// Failures are listed in the dialog before it closes.
Future<SyncRun> runPlanWithProgress(
  BuildContext context, {
  required SyncPlan plan,
  required Future<SyncRun> Function(
          void Function(SyncProgress) onProgress, bool Function() isCancelled)
      run,
}) async {
  final outcome = await showDialog<SyncRun>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(plan: plan, run: run),
  );
  return outcome ?? SyncRun(plan, 0, const []);
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.plan, required this.run});

  final SyncPlan plan;
  final Future<SyncRun> Function(
      void Function(SyncProgress) onProgress, bool Function() isCancelled) run;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  SyncProgress? _progress;
  SyncRun? _outcome;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final outcome = await widget.run(
      (p) {
        if (mounted) setState(() => _progress = p);
      },
      () => _cancelling,
    );
    if (!mounted) return;
    if (outcome.errors.isEmpty) {
      Navigator.pop(context, outcome);
    } else {
      setState(() => _outcome = outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outcome = _outcome;
    if (outcome != null) return SyncErrorsDialog(outcome: outcome);

    final p = _progress;
    return AlertDialog(
      title: Text(_cancelling ? 'Stopping…' : 'Synchronizing…'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: p?.fraction),
            const SizedBox(height: 12),
            Text(
              p == null
                  ? ''
                  : '${formatCount(p.done)} of ${formatCount(p.total)} steps'
                      '${p.totalBytes > 0 ? ' · ${formatSize(p.bytesDone)} '
                          'of ${formatSize(p.totalBytes)}' : ''}',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(p?.currentPath ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle.copyWith(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _cancelling ? null : () => setState(() => _cancelling = true),
          child: const Text('Stop'),
        ),
      ],
    );
  }
}

/// Lists the steps of [outcome] that failed.
Future<void> showSyncErrors(BuildContext context, SyncRun outcome) =>
    showDialog<void>(
      context: context,
      builder: (_) => SyncErrorsDialog(outcome: outcome),
    );

class SyncErrorsDialog extends StatelessWidget {
  const SyncErrorsDialog({super.key, required this.outcome});

  final SyncRun outcome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = outcome.errors.length;
    return AlertDialog(
      icon: Icon(Icons.error_outline, color: scheme.error),
      title: Text('$failed ${failed == 1 ? 'step' : 'steps'} failed'),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${formatCount(outcome.succeeded.length)} of '
              '${formatCount(outcome.plan.ops.length)} steps finished.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(10),
                children: [
                  for (final e in outcome.errors)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                            text: e.op.path,
                            style: monoStyle.copyWith(fontSize: 12)),
                        TextSpan(
                            text: '  ${e.message}',
                            style: TextStyle(
                                fontSize: 12.5, color: scheme.error)),
                      ])),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, outcome),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
