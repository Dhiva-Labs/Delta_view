import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../compare/diff_side.dart';
import '../../diff/structured/structured_compare.dart';
import '../../theme.dart';
import '../file_diff_view.dart';
import '../shortcuts/app_shortcuts.dart';
import 'table_diff_panel.dart';
import 'tree_diff_panel.dart';

/// Whether [name] is a JSON / YAML / CSV / TSV file the structured view
/// handles.
bool isStructuredFile(String name) => StructuredFormat.of(name) != null;

/// Below this many characters, diffing on the UI thread is quicker than
/// starting an isolate, and keeps option toggles instant.
const _isolateThreshold = 64 * 1024;

/// Key-aware comparison of JSON, YAML and CSV / TSV, with a switch to the
/// plain text diff. Files that do not parse open in the text diff, with a
/// banner saying what is wrong and where.
class StructuredDiffView extends StatefulWidget {
  const StructuredDiffView({
    super.key,
    required this.left,
    required this.right,
    this.title,
    this.onBack,
  });

  final DiffSide left;
  final DiffSide right;
  final String? title;
  final VoidCallback? onBack;

  @override
  State<StructuredDiffView> createState() => _StructuredDiffViewState();
}

class _StructuredDiffViewState extends State<StructuredDiffView> {
  bool _structured = true;
  bool _loaded = false;
  Object? _readError;

  /// Null for a file that does not exist.
  String? _leftText;
  String? _rightText;

  late final StructuredFormat _leftFormat =
      StructuredFormat.of(widget.left.label) ?? StructuredFormat.json;
  late final StructuredFormat _rightFormat =
      StructuredFormat.of(widget.right.label) ?? _leftFormat;

  StructuredOutcome? _outcome;
  bool _computing = false;
  int _generation = 0;

  TreeDiffOptions _treeOptions = const TreeDiffOptions();
  TableDiffOptions _tableOptions = const TableDiffOptions();

  /// Bumped on reload so the text view rereads the files too.
  int _textKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loaded = false;
      _readError = null;
      _outcome = null;
      _textKey++;
    });
    try {
      final texts =
          await Future.wait([_read(widget.left), _read(widget.right)]);
      if (!mounted) return;
      _leftText = texts[0];
      _rightText = texts[1];
      setState(() => _loaded = true);
      await _compute(firstRun: true);
    } catch (e) {
      if (mounted) setState(() => _readError = e);
    }
  }

  static Future<String?> _read(DiffSide side) async {
    if (side.isMemory) return side.initialText ?? '';
    final bytes = await side.read();
    return bytes == null ? null : decodeText(bytes);
  }

  Future<void> _compute({bool firstRun = false}) async {
    final generation = ++_generation;
    setState(() => _computing = true);
    final l = _leftText, r = _rightText;
    final size = (l?.length ?? 0) + (r?.length ?? 0);
    final outcome = size > _isolateThreshold
        ? await _computeInIsolate(
            l, r, _leftFormat, _rightFormat, _treeOptions, _tableOptions)
        : compareStructured(
            leftText: l,
            rightText: r,
            leftFormat: _leftFormat,
            rightFormat: _rightFormat,
            treeOptions: _treeOptions,
            tableOptions: _tableOptions,
          );
    if (!mounted || generation != _generation) return;
    setState(() {
      _outcome = outcome;
      _computing = false;
      // Something that is not structure is best read as text.
      if (firstRun && (outcome is ParseFailure || outcome is FormatMismatch)) {
        _structured = false;
      }
    });
  }

  /// Static so the isolate closure captures only plain data.
  static Future<StructuredOutcome> _computeInIsolate(
    String? left,
    String? right,
    StructuredFormat leftFormat,
    StructuredFormat rightFormat,
    TreeDiffOptions treeOptions,
    TableDiffOptions tableOptions,
  ) =>
      Isolate.run(() => compareStructured(
            leftText: left,
            rightText: right,
            leftFormat: leftFormat,
            rightFormat: rightFormat,
            treeOptions: treeOptions,
            tableOptions: tableOptions,
          ));

  void _setTreeOptions(TreeDiffOptions options) {
    if (options == _treeOptions) return;
    _treeOptions = options;
    _compute();
  }

  void _setTableOptions(TableDiffOptions options) {
    _tableOptions = options;
    _compute();
  }

  String get _title {
    final l = widget.left.label, r = widget.right.label;
    return widget.title ?? (l == r ? l : '$l ↔ $r');
  }

  /// What is wrong with the files as structure, or null when nothing is.
  String? get _problem {
    final outcome = _outcome;
    return switch (outcome) {
      ParseFailure f => "Couldn't read "
          '${(f.leftSide ? widget.left : widget.right).label} as '
          '${f.format.label}: ${f.error.message}'
          '${f.error.line == null ? '' : ' (${f.error.location})'}.',
      FormatMismatch m => 'A ${m.left.label} file and a ${m.right.label} '
          'file have no structure in common.',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return CallbackShortcuts(
      bindings: bindActions({AppAction.refresh: _load}),
      child: Column(
        children: [
          _header(context),
          if (problem != null)
            _ProblemBanner(
              message: problem,
              structured: _structured,
              onRetry: _load,
            ),
          Expanded(child: _structured ? _structuredBody(context) : _textBody()),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outcome = _outcome;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 6),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Change files',
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          const SizedBox(width: 4),
          Icon(
              _leftFormat.isTable
                  ? Icons.table_chart_outlined
                  : Icons.account_tree_outlined,
              size: 18,
              color: scheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 14),
          if (_structured && outcome != null)
            Flexible(child: _Summary(outcome: outcome)),
          const Spacer(),
          if (_computing && _outcome != null)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style:
                SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(
                value: true,
                icon: Icon(
                    _leftFormat.isTable
                        ? Icons.table_rows_outlined
                        : Icons.account_tree_outlined,
                    size: 16),
                label: const Text('Structured'),
              ),
              const ButtonSegment(
                value: false,
                icon: Icon(Icons.notes, size: 16),
                label: Text('Text'),
              ),
            ],
            selected: {_structured},
            onSelectionChanged: (s) => setState(() => _structured = s.first),
          ),
        ],
      ),
    );
  }

  Widget _textBody() => FileDiffView(
        key: ValueKey(_textKey),
        left: widget.left,
        right: widget.right,
        title: widget.title,
      );

  Widget _structuredBody(BuildContext context) {
    final error = _readError;
    if (error != null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Could not read the files',
        detail: '$error',
        onRetry: _load,
      );
    }
    final outcome = _outcome;
    if (!_loaded || outcome == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (outcome) {
      TreeOutcome o => TreeDiffPanel(
          result: o.result,
          options: _treeOptions,
          onOptionsChanged: _setTreeOptions,
        ),
      TableOutcome o => TableDiffPanel(
          diff: o.diff,
          options: _tableOptions,
          onOptionsChanged: _setTableOptions,
        ),
      ParseFailure _ || FormatMismatch _ => _Message(
          icon: Icons.data_object,
          title: 'No structured view for these files',
          detail: _problem ?? '',
          onRetry: _load,
          actions: [
            TextButton.icon(
              onPressed: () => setState(() => _structured = false),
              icon: const Icon(Icons.notes, size: 18),
              label: const Text('Show the text diff'),
            ),
          ],
        ),
    };
  }
}

/// "+2 −1 ~3" for the whole comparison.
class _Summary extends StatelessWidget {
  const _Summary({required this.outcome});

  final StructuredOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final (int added, int removed, int changed, String noun) =
        switch (outcome) {
      TreeOutcome o => (
          o.result.root.added,
          o.result.root.removed,
          o.result.root.changed,
          'values'
        ),
      TableOutcome o => (
          o.diff.count(RowStatus.added),
          o.diff.count(RowStatus.removed),
          o.diff.count(RowStatus.changed),
          'rows'
        ),
      _ => (0, 0, 0, ''),
    };
    if (outcome is! TreeOutcome && outcome is! TableOutcome) {
      return const SizedBox.shrink();
    }
    Widget chip(String text, Color color) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        );
    if (added + removed + changed == 0) {
      return chip('identical $noun', palette.added);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0) chip('+$added', palette.added),
        if (removed > 0) chip('−$removed', palette.removed),
        if (changed > 0) chip('~$changed', palette.modified),
        Flexible(
          child: Text(noun,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({
    required this.message,
    required this.structured,
    required this.onRetry,
  });

  final String message;
  final bool structured;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: palette.modifiedBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.modified.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: palette.modified),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              structured ? message : '$message Showing the text diff.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reload'),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onRetry,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onRetry;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reload'),
                ),
                ...actions,
              ],
            ),
          ],
        ),
      ),
    );
  }
}
