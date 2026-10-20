import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compare/comparison.dart';
import '../compare/folder_compare.dart';
import '../compare/folder_format.dart';
import '../compare/folder_report.dart';
import '../compare/folder_sync.dart';
import '../compare/folder_watch.dart';
import '../compare/ignore_rules.dart';
import '../compare/sources/file_source.dart';
import '../settings/app_settings.dart';
import '../theme.dart';
import 'folder/entry_actions.dart';
import 'folder/folder_header.dart';
import 'folder/ignore_dialog.dart';
import 'folder/sync_dialog.dart';
import 'folder/tree_model.dart';
import 'folder/tree_rows.dart';
import 'shell.dart';
import 'shortcuts/app_shortcuts.dart';

/// Compares two folders (on this machine, in archives or on servers) as a
/// Meld-style dual-pane tree, and copies, deletes or synchronizes entries
/// between them.
class FolderDiffView extends StatefulWidget {
  const FolderDiffView({
    super.key,
    required this.left,
    required this.right,
    this.onBack,
  });

  final SourceSpec left;
  final SourceSpec right;
  final VoidCallback? onBack;

  @override
  State<FolderDiffView> createState() => _FolderDiffViewState();
}

class _FolderDiffViewState extends State<FolderDiffView> {
  // ---- scanning ----
  FolderScan? _scan;
  DateTime _scanStarted = DateTime.now();
  final _progress = ValueNotifier<ScanProgress?>(null);
  ScanResult? _result;
  ScanFailure? _failure;

  /// The first scan was cancelled: there is nothing to show.
  bool _cancelled = false;

  /// A rescan was asked for while a scan or a sync was running.
  bool _rescanQueued = false;
  Timer? _settingsDebounce;
  String _scanSettings = '';

  // ---- options for this comparison ----
  late bool _quick =
      appSettings.folderCompareMethod == FolderCompareMethod.sizeAndDate;

  /// The user flipped [_quick] here, so it stops following settings.
  bool _quickChosen = false;
  final _temporaryPatterns = <String>[];

  // ---- tree and selection ----
  final _tree = FolderTreeModel();
  String? _cursor;
  final _selected = <String>{};
  String? _anchor;
  String? _lastTapPath;
  DateTime _lastTapTime = DateTime(0);
  final _treeFocus = FocusNode(debugLabel: 'folder tree');
  final _searchFocus = FocusNode(debugLabel: 'folder search');
  final _scroll = ScrollController();
  final _menu = MenuController();
  final _treeKey = GlobalKey();

  // ---- changing things ----
  bool _autoRefresh = false;
  FolderWatcher? _watcher;
  IgnoreRules _watchRules = IgnoreRules(const []);

  /// A copy, delete or sync is running.
  bool _busy = false;
  final _sources = <Side, Future<FileSource>>{};

  @override
  void initState() {
    super.initState();
    _tree.filter = TreeFilter.fromSetting(appSettings.defaultFolderFilter);
    appSettings.addListener(_onSettingsChanged);
    _treeFocus.addListener(_onFocusChanged);
    _startScan();
  }

  @override
  void dispose() {
    // Closing the tab stops the scan at once instead of letting it run on.
    _scan?.cancel();
    _watcher?.dispose();
    _settingsDebounce?.cancel();
    appSettings.removeListener(_onSettingsChanged);
    _progress.dispose();
    _treeFocus.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    for (final source in _sources.values) {
      source.then((s) => s.close(), onError: (_) {});
    }
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  // ---- settings ----

  /// The settings a scan depends on; a change means the results are stale.
  String _scanSettingsKey() => jsonEncode([
        appSettings.ignorePatterns,
        appSettings.respectGitignore,
        appSettings.compareOptions.toJson(),
        appSettings.folderCompareMethod.name,
      ]);

  void _onSettingsChanged() {
    if (!mounted) return;
    if (_scanSettingsKey() != _scanSettings) {
      if (!_quickChosen) {
        _quick =
            appSettings.folderCompareMethod == FolderCompareMethod.sizeAndDate;
      }
      // Settings fields can change on every keystroke; rescan once they
      // settle.
      _settingsDebounce?.cancel();
      _settingsDebounce =
          Timer(const Duration(milliseconds: 600), _startScan);
    }
    // Dates, density and colours show straight away.
    setState(() {});
  }

  List<String> get _patterns =>
      [...appSettings.ignorePatterns, ..._temporaryPatterns];

  bool get _caseSensitiveNames => !(Platform.isWindows || Platform.isMacOS);

  // ---- scanning ----

  void _startScan() {
    _settingsDebounce?.cancel();
    if (!mounted) return;
    if (_busy) {
      _rescanQueued = true;
      return;
    }
    _scan?.cancel();
    _scanSettings = _scanSettingsKey();
    _watchRules = IgnoreRules(_patterns, caseSensitive: _caseSensitiveNames);
    _progress.value = null;
    final scan = FolderScan.start(
      widget.left,
      widget.right,
      options: ScanOptions(
        ignorePatterns: _patterns,
        respectGitignore: appSettings.respectGitignore,
        quick: _quick,
        compareOptions: appSettings.compareOptions,
        caseSensitiveIgnore: _caseSensitiveNames,
      ),
      onProgress: (p) => _progress.value = p,
    );
    setState(() {
      _scan = scan;
      _scanStarted = DateTime.now();
      _cancelled = false;
      _failure = null;
    });
    scan.result.then(
      (result) => _onScanDone(scan, result),
      onError: (Object e) => _onScanFailed(scan, e),
    );
  }

  void _onScanDone(FolderScan scan, ScanResult result) {
    if (!mounted || _scan != scan) return;
    final first = _result == null;
    setState(() {
      _scan = null;
      _result = result;
      _tree.root = result.root;
      if (first) {
        for (final child in result.root.children) {
          if (child.isDirectory && child.hasChanges) {
            _tree.expanded.add(child.relativePath);
          }
        }
        _tree.expansionChanged();
        final rows = _tree.rows;
        if (rows.isNotEmpty) _cursor = rows.first.node.relativePath;
      }
      _keepSelection();
    });
    if (first) _focusTreeIfShown();
    _updateWatcher();
    if (_rescanQueued) {
      _rescanQueued = false;
      _startScan();
    }
  }

  void _onScanFailed(FolderScan scan, Object error) {
    if (!mounted || _scan != scan) return;
    setState(() {
      _scan = null;
      if (error is ScanCancelled) {
        _cancelled = _result == null;
      } else {
        _failure = error is ScanFailure ? error : ScanFailure('$error');
      }
    });
  }

  void _cancelScan() => _scan?.cancel();

  /// After a rescan or a filter change: drops selected entries that are
  /// gone or hidden, and moves the cursor to the nearest folder still
  /// shown. When nothing selected is left, the cursor row takes over, the
  /// way a file manager selects the next item after a delete.
  void _keepSelection() {
    final hadSelection = _selected.isNotEmpty;
    _selected.removeWhere((path) => _tree.indexOf(path) < 0);
    var cursor = _cursor;
    while (cursor != null && _tree.indexOf(cursor) < 0) {
      cursor = cursor.isEmpty
          ? null
          : cursor.contains('/')
              ? cursor.substring(0, cursor.lastIndexOf('/'))
              : null;
    }
    _cursor = cursor ??
        (_tree.rows.isEmpty ? null : _tree.rows.first.node.relativePath);
    if (hadSelection && _selected.isEmpty && _cursor != null) {
      _selected.add(_cursor!);
    }
    if (_anchor == null || _tree.indexOf(_anchor!) < 0) _anchor = _cursor;
  }

  /// Gives the tree keyboard focus when this tab is the one showing and
  /// the user is not typing somewhere else.
  void _focusTreeIfShown() {
    final handle = TabScope.maybeOf(context);
    final shell = context.findAncestorStateOfType<TabbedShellState>();
    if (handle != null && shell != null) {
      final tabs = shell.tabs;
      final active = shell.activeIndex;
      if (active >= tabs.length || tabs[active].id != handle.tabId) return;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) return;
    _treeFocus.requestFocus();
  }

  // ---- tree navigation ----

  List<CompareNode> get _targets {
    final paths = _selected.isNotEmpty ? _selected : {?_cursor};
    final nodes = [
      for (final path in paths) ?_tree.nodeAt(path),
    ];
    int order(CompareNode n) {
      final i = _tree.indexOf(n.relativePath);
      return i < 0 ? 1 << 30 : i;
    }

    return nodes..sort((a, b) => order(a) - order(b));
  }

  void _setCursor(String path, {bool extend = false}) {
    setState(() {
      _cursor = path;
      if (extend && _anchor != null) {
        _selectRange(_anchor!, path);
      } else {
        _selected
          ..clear()
          ..add(path);
        _anchor = path;
      }
    });
    _ensureVisible(path);
  }

  void _selectRange(String from, String to, {bool add = false}) {
    final a = _tree.indexOf(from), b = _tree.indexOf(to);
    if (!add) _selected.clear();
    if (a < 0 || b < 0) {
      _selected.add(to);
      return;
    }
    final rows = _tree.rows;
    for (var i = a < b ? a : b; i <= (a < b ? b : a); i++) {
      _selected.add(rows[i].node.relativePath);
    }
  }

  void _moveCursor(int delta, {bool extend = false}) {
    final rows = _tree.rows;
    if (rows.isEmpty) return;
    final current = _cursor == null ? -1 : _tree.indexOf(_cursor!);
    final next = current < 0
        ? (delta > 0 ? 0 : rows.length - 1)
        : (current + delta).clamp(0, rows.length - 1);
    _setCursor(rows[next].node.relativePath, extend: extend);
  }

  void _ensureVisible(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final index = _tree.indexOf(path);
      if (index < 0) return;
      final extent = rowExtentFor(appSettings.density);
      final position = _scroll.position;
      final top = index * extent, bottom = top + extent;
      if (top < position.pixels) {
        _scroll.jumpTo(top);
      } else if (bottom > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(bottom - position.viewportDimension);
      }
    });
  }

  void _toggle(CompareNode node) {
    if (!node.isDirectory) return;
    setState(() => _tree.setExpanded(node, !_tree.isExpanded(node)));
  }

  void _setAllExpanded(bool open) {
    setState(() {
      open ? _tree.expandAll() : _tree.collapseAll();
      _keepSelection();
    });
    if (_cursor != null) _ensureVisible(_cursor!);
  }

  void _onRowTapDown(CompareNode node) {
    _treeFocus.requestFocus();
    final keys = HardwareKeyboard.instance;
    final toggleKey = keys.isControlPressed || keys.isMetaPressed;
    final rangeKey = keys.isShiftPressed;
    final path = node.relativePath;
    final now = DateTime.now();
    final second = !toggleKey &&
        !rangeKey &&
        _lastTapPath == path &&
        now.difference(_lastTapTime) < const Duration(milliseconds: 400);
    _lastTapPath = second ? null : path;
    _lastTapTime = now;

    setState(() {
      _cursor = path;
      if (rangeKey && _anchor != null) {
        _selectRange(_anchor!, path, add: toggleKey);
      } else if (toggleKey) {
        if (!_selected.remove(path)) _selected.add(path);
        _anchor = path;
      } else {
        _selected
          ..clear()
          ..add(path);
        _anchor = path;
      }
    });
    if (toggleKey || rangeKey) return;
    if (node.isDirectory) {
      // A click opens or closes a folder; the second click of a double
      // click does not undo the first.
      if (!second) _toggle(node);
    } else if (second) {
      _openComparison(node);
    }
  }

  void _onRowSecondaryTapDown(CompareNode node, TapDownDetails details) {
    _treeFocus.requestFocus();
    setState(() {
      // Right-clicking outside the selection acts on that row alone.
      if (!_selected.contains(node.relativePath)) {
        _selected
          ..clear()
          ..add(node.relativePath);
        _anchor = node.relativePath;
      }
      _cursor = node.relativePath;
    });
    final box = _treeKey.currentContext?.findRenderObject() as RenderBox?;
    _menu.open(position: box?.globalToLocal(details.globalPosition));
  }

  void _openMenuAtCursor() {
    final cursor = _cursor;
    final index = cursor == null ? -1 : _tree.indexOf(cursor);
    if (index < 0 || !_scroll.hasClients) {
      _menu.open();
      return;
    }
    final extent = rowExtentFor(appSettings.density);
    _menu.open(
        position: Offset(64, (index + 1) * extent - _scroll.offset));
  }

  KeyEventResult _onTreeKey(FocusNode focus, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_result == null) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (AppAction.openEntry.activator.accepts(event, keys)) {
      final node = _cursor == null ? null : _tree.nodeAt(_cursor!);
      if (node == null) return KeyEventResult.ignored;
      node.isDirectory ? _toggle(node) : _openComparison(node);
      return KeyEventResult.handled;
    }
    if (keys.isAltPressed || keys.isMetaPressed) return KeyEventResult.ignored;
    final shift = keys.isShiftPressed, control = keys.isControlPressed;
    final rows = _tree.rows;
    final node = _cursor == null ? null : _tree.nodeAt(_cursor!);
    final key = event.logicalKey;

    if (control) {
      if (key == LogicalKeyboardKey.keyA) {
        setState(() {
          _selected
            ..clear()
            ..addAll(rows.map((r) => r.node.relativePath));
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final page = _scroll.hasClients
        ? (_scroll.position.viewportDimension /
                    rowExtentFor(appSettings.density))
                .floor() -
            1
        : 10;
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        _moveCursor(1, extend: shift);
      case LogicalKeyboardKey.arrowUp:
        _moveCursor(-1, extend: shift);
      case LogicalKeyboardKey.pageDown:
        _moveCursor(page < 1 ? 1 : page, extend: shift);
      case LogicalKeyboardKey.pageUp:
        _moveCursor(page < 1 ? -1 : -page, extend: shift);
      case LogicalKeyboardKey.home:
        _moveCursor(-rows.length, extend: shift);
      case LogicalKeyboardKey.end:
        _moveCursor(rows.length, extend: shift);
      case LogicalKeyboardKey.arrowRight:
        if (node == null || !node.isDirectory) return KeyEventResult.handled;
        if (!_tree.isExpanded(node)) {
          _toggle(node);
        } else {
          final index = _tree.indexOf(node.relativePath);
          final hasChild = index + 1 < rows.length &&
              rows[index + 1].depth > rows[index].depth;
          if (hasChild) {
            _setCursor(rows[index + 1].node.relativePath);
          }
        }
      case LogicalKeyboardKey.arrowLeft:
        if (node == null) return KeyEventResult.handled;
        if (node.isDirectory && _tree.isExpanded(node)) {
          _toggle(node);
        } else if (node.relativePath.contains('/')) {
          final parent = node.relativePath
              .substring(0, node.relativePath.lastIndexOf('/'));
          if (_tree.indexOf(parent) >= 0) _setCursor(parent);
        }
      case LogicalKeyboardKey.space:
        final cursor = _cursor;
        if (cursor == null) return KeyEventResult.handled;
        setState(() {
          if (!_selected.remove(cursor)) _selected.add(cursor);
          _anchor = cursor;
        });
      case LogicalKeyboardKey.contextMenu:
        _openMenuAtCursor();
      case LogicalKeyboardKey.f10 when shift:
        _openMenuAtCursor();
      case LogicalKeyboardKey.escape when _selected.length > 1:
        final cursor = _cursor;
        setState(() {
          _selected.clear();
          if (cursor != null) _selected.add(cursor);
        });
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---- opening entries ----

  void _openComparison(CompareNode node) {
    final relative = node.relativePath;
    final shell = TabbedShellState.of(context);
    if (node.isDirectory) {
      if (!node.existsLeft || !node.existsRight) {
        _snack('“${node.name}” exists on one side only.');
        return;
      }
      shell.openComparison(FolderComparison(
          widget.left.child(relative), widget.right.child(relative)));
      return;
    }
    if (node.isTypeConflict) {
      _snack('“${node.name}” is a file on one side and a folder on the '
          'other, so there is nothing to compare line by line.');
      return;
    }
    // Pass both sides even when one is missing — the diff view can then
    // create the missing file on save.
    shell.openComparison(
      FileComparison(
        widget.left.child(relative),
        widget.right.child(relative),
        titleOverride: relative,
      ),
      title: node.name,
    );
  }

  Future<FileSource> _source(Side side) => _sources[side] ??=
      FileSource.open(side == Side.left ? widget.left : widget.right)
        ..ignore();

  Future<String?> _localPath(Side side, CompareNode node) async {
    try {
      return (await _source(side)).localPath(node.relativePath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyPath(Side side, CompareNode node) async {
    final spec = side == Side.left ? widget.left : widget.right;
    final path = await _localPath(side, node) ??
        spec.child(node.relativePath).description;
    await Clipboard.setData(ClipboardData(text: path));
    _snack('Copied $path');
  }

  Future<void> _showInFileManager(Side side, CompareNode node) async {
    final path = await _localPath(side, node);
    if (path == null) return;
    await _launch(fileManagerCommand(path), 'the file manager');
  }

  Future<void> _openInEditor(Side side, CompareNode node) async {
    final path = await _localPath(side, node);
    if (path == null) return;
    final template = appSettings.externalEditor.trim();
    await _launch(editorCommand(template, path),
        template.isEmpty ? 'the default app' : 'the external editor');
  }

  Future<void> _launch(List<String> command, String what) async {
    try {
      await launchDetached(command);
    } catch (e) {
      _snack('Could not open $what (${command.first}): '
          '${e is ProcessException ? e.message : e}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }

  // ---- changing the folders ----

  String _sideName(Side side) => side == Side.left ? 'left' : 'right';

  Future<void> _copy(Side from) async {
    final to = from.other;
    final plan = planCopy(_targets, from: from);
    if (plan.isEmpty) {
      _snack('Nothing to copy: the ${_sideName(to)} side already has it.');
      return;
    }
    if (plan.destructive &&
        !await confirmPlan(
          context,
          plan: plan,
          title: 'Copy to the ${_sideName(to)} and overwrite?',
          confirmLabel: 'Copy and overwrite',
          leftLabel: widget.left.label,
          rightLabel: widget.right.label,
        )) {
      return;
    }
    await _runPlan(plan);
  }

  Future<void> _delete(Side side) async {
    final plan = planDelete(_targets, side: side);
    if (plan.isEmpty) return;
    final n = plan.deleteCount;
    final ok = await confirmPlan(
      context,
      plan: plan,
      title: 'Delete on the ${_sideName(side)}?',
      confirmLabel: n == 1 ? 'Delete' : 'Delete $n entries',
      leftLabel: widget.left.label,
      rightLabel: widget.right.label,
    );
    if (ok) await _runPlan(plan);
  }

  Future<void> _synchronize() async {
    final result = _result;
    if (result == null || _busy) return;
    if (!result.leftWritable && !result.rightWritable) {
      _snack('Both sides are read-only, so they cannot be synchronized.');
      return;
    }
    final selection = [
      for (final path in _selected)
        if (path.isNotEmpty) ?_tree.nodeAt(path),
    ];
    final plan = await showSyncDialog(
      context,
      root: result.root,
      selection: selection,
      leftWritable: result.leftWritable,
      rightWritable: result.rightWritable,
      leftLabel: widget.left.label,
      rightLabel: widget.right.label,
    );
    if (plan != null && mounted) await _runPlan(plan);
  }

  /// Runs [plan], then rescans. Long plans get a progress dialog that can
  /// stop them; short ones just run.
  Future<void> _runPlan(SyncPlan plan) async {
    setState(() => _busy = true);
    try {
      final left = await _source(Side.left);
      final right = await _source(Side.right);
      if (!mounted) return;
      final long = plan.ops.length > 20 || plan.bytesToWrite > 20 * 1000 * 1000;
      SyncRun outcome;
      if (long) {
        outcome = await runPlanWithProgress(
          context,
          plan: plan,
          run: (onProgress, isCancelled) => runSyncPlan(plan,
              left: left,
              right: right,
              onProgress: onProgress,
              isCancelled: isCancelled),
        );
      } else {
        outcome = await runSyncPlan(plan, left: left, right: right);
        if (outcome.errors.isNotEmpty && mounted) {
          await showSyncErrors(context, outcome);
        }
      }
      _snack(_summary(outcome));
    } catch (e) {
      _snack('Could not change the folders: $e');
    } finally {
      _busy = false;
      _rescanQueued = false;
      if (mounted) _startScan();
    }
  }

  String _summary(SyncRun outcome) {
    var copied = 0, overwritten = 0, deleted = 0;
    for (final op in outcome.succeeded) {
      switch (op.kind) {
        case SyncOpKind.copy:
        case SyncOpKind.createFolder:
          copied++;
        case SyncOpKind.overwrite:
          overwritten++;
        case SyncOpKind.delete:
          deleted++;
      }
    }
    final parts = [
      if (copied > 0) '${formatCount(copied)} copied',
      if (overwritten > 0) '${formatCount(overwritten)} overwritten',
      if (deleted > 0) '${formatCount(deleted)} deleted',
      if (outcome.errors.isNotEmpty)
        '${formatCount(outcome.errors.length)} failed',
    ];
    final what = parts.isEmpty ? 'nothing changed' : parts.join(', ');
    return outcome.stopped ? 'Stopped: $what' : 'Done: $what';
  }

  Future<void> _ignoreTargets() async {
    final patterns = [
      for (final node in topmost(_targets))
        if (node.relativePath.isNotEmpty) exactPattern(node.relativePath),
    ];
    if (patterns.isEmpty) return;
    setState(() => _temporaryPatterns.addAll(
        patterns.where((p) => !_temporaryPatterns.contains(p))));
    _startScan();
  }

  Future<void> _editIgnores() async {
    final result = _result;
    final updated = await showIgnoreDialog(
      context,
      settingsPatterns: appSettings.ignorePatterns,
      respectGitignore: appSettings.respectGitignore,
      temporary: _temporaryPatterns,
      ignoredCount: result?.ignoredCount ?? 0,
      ignoredPaths: result?.ignoredPaths ?? const [],
    );
    if (updated == null || !mounted) return;
    setState(() => _temporaryPatterns
      ..clear()
      ..addAll(updated));
    _startScan();
  }

  void _showIssues(ScanResult result) {
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded,
              color: DiffPalette.of(context).modified),
          title: Text('${result.issues.length} '
              '${result.issues.length == 1 ? 'entry' : 'entries'} '
              'could not be read'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final issue in result.issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: issue.path,
                          style: monoStyle.copyWith(fontSize: 12)),
                      TextSpan(
                          text: '  ${issue.message}',
                          style: TextStyle(
                              fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ])),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // ---- reports ----

  Future<void> _export({required bool html}) async {
    final result = _result;
    if (result == null) return;
    final extension = html ? 'html' : 'csv';
    String safe(String s) => s.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final location = await getSaveLocation(
      suggestedName: '${safe(widget.left.label)}-vs-'
          '${safe(widget.right.label)}.$extension',
      acceptedTypeGroups: [
        html
            ? const XTypeGroup(label: 'HTML page', extensions: ['html', 'htm'])
            : const XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) return;
    var path = location.path;
    if (!path.toLowerCase().endsWith('.$extension') &&
        !(html && path.toLowerCase().endsWith('.htm'))) {
      path = '$path.$extension';
    }
    final query = _tree.query;
    final report = FolderReport(
      result: result,
      leftDescription: widget.left.description,
      rightDescription: widget.right.description,
      include: _tree.isShown,
      scopeLabel: query.isEmpty
          ? _tree.filter.label
          : '${_tree.filter.label}, names containing “$query”',
    );
    try {
      await File(path).writeAsString(html ? report.toHtml() : report.toCsv());
      _snack('Saved the report to $path');
    } on FileSystemException catch (e) {
      _snack('Could not save the report: ${e.osError?.message ?? e.message}');
    }
  }

  // ---- watching ----

  void _setAutoRefresh(bool on) {
    setState(() => _autoRefresh = on);
    _updateWatcher();
    if (on) _startScan();
  }

  void _updateWatcher() {
    final result = _result;
    if (!_autoRefresh || result == null) {
      _watcher?.dispose();
      _watcher = null;
      return;
    }
    final watcher = _watcher ??= FolderWatcher(
      onChange: _onFilesChanged,
      isIgnored: (path) => _watchRules.coversPath(path),
    );
    watcher.watch([
      for (final side in Side.values)
        if ((side == Side.left ? widget.left : widget.right)
            case LocalSource(:final path))
          WatchRoot(path, _foldersOn(result.root, side)),
    ]);
    if (mounted) setState(() {});
  }

  /// Folders present on [side], shallow ones first.
  static List<String> _foldersOn(CompareNode root, Side side) {
    final out = <String>[];
    final queue = [root];
    for (var i = 0; i < queue.length; i++) {
      for (final child in queue[i].children) {
        if (child.isDirectory && child.existsOn(side)) {
          out.add(child.relativePath);
          queue.add(child);
        }
      }
    }
    return out;
  }

  void _onFilesChanged() {
    if (!mounted || _busy) return;
    if (_scan != null) {
      _rescanQueued = true;
      return;
    }
    _startScan();
  }

  bool get _canWatch =>
      widget.left is LocalSource || widget.right is LocalSource;

  // ---- building ----

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.refresh: _startScan,
        AppAction.expandAll: () => _setAllExpanded(true),
        AppAction.collapseAll: () => _setAllExpanded(false),
        AppAction.syncFolders: _synchronize,
        AppAction.find: () => _searchFocus.requestFocus(),
      }),
      child: Column(
        children: [
          _pathBar(result),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _body(result),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ScanResult? result) {
    final failure = _failure;
    if (failure != null) {
      return ScanMessageView(
        key: const ValueKey('failure'),
        icon: failure.unsupported
            ? Icons.extension_off_outlined
            : Icons.error_outline,
        title: failure.unsupported
            ? 'Not available yet'
            : 'Comparison failed',
        message: failure.message,
        error: !failure.unsupported,
        actions: [
          if (!failure.unsupported)
            OutlinedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          if (widget.onBack != null)
            TextButton.icon(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Choose other folders'),
            ),
        ],
      );
    }
    if (result == null) {
      if (_cancelled) {
        return ScanMessageView(
          key: const ValueKey('cancelled'),
          icon: Icons.stop_circle_outlined,
          title: 'Scan cancelled',
          message: 'Nothing was compared.',
          actions: [
            OutlinedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan again'),
            ),
          ],
        );
      }
      return ScanningView(
        key: const ValueKey('scanning'),
        progress: _progress,
        started: _scanStarted,
        onCancel: _cancelScan,
      );
    }
    return KeyedSubtree(
      key: const ValueKey('result'),
      child: _resultView(result),
    );
  }

  Widget _pathBar(ScanResult? result) {
    final scanning = _scan != null;
    final watcher = _watcher;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Change folders',
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: PathChip(
              label: widget.left.label,
              path: widget.left.description,
              readOnly: result != null && !result.leftWritable,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.compare_arrows, size: 18),
          ),
          Expanded(
            child: PathChip(
              label: widget.right.label,
              path: widget.right.description,
              readOnly: result != null && !result.rightWritable,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: _quick
                ? 'Quick compare: files with the same size and modification '
                    'time count as identical, without reading them'
                : 'Full compare: file contents are read and compared',
            child: FilterChip(
              avatar: Icon(_quick ? Icons.bolt : Icons.bolt_outlined, size: 16),
              label: const Text('Quick compare'),
              selected: _quick,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (on) {
                setState(() {
                  _quick = on;
                  _quickChosen = true;
                });
                _startScan();
              },
            ),
          ),
          const SizedBox(width: 4),
          if (_canWatch)
            IconButton(
              isSelected: _autoRefresh,
              tooltip: !_autoRefresh
                  ? 'Rescan automatically when files change'
                  : watcher == null
                      ? 'Rescanning automatically'
                      : 'Watching ${formatCount(watcher.watchedCount)} '
                          '${watcher.watchedCount == 1 ? 'folder' : 'folders'}'
                          '${watcher.capped ? ' (too many to watch them all)' : ''}'
                          ' — click to stop',
              onPressed: () => _setAutoRefresh(!_autoRefresh),
              icon: const Icon(Icons.autorenew, size: 20),
              selectedIcon: const Icon(Icons.autorenew, size: 20),
              style: _autoRefresh
                  ? IconButton.styleFrom(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.7))
                  : null,
            ),
          IconButton(
            tooltip: 'Rescan (${AppAction.refresh.keyLabel})',
            onPressed: scanning ? null : _startScan,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.description_outlined, size: 18),
                onPressed: result == null ? null : () => _export(html: true),
                child: const Text('Export HTML report…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.table_chart_outlined, size: 18),
                onPressed: result == null ? null : () => _export(html: false),
                child: const Text('Export CSV…'),
              ),
            ],
            builder: (context, controller, _) => IconButton(
              tooltip: 'Export',
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.ios_share, size: 19),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultView(ScanResult result) {
    final palette = DiffPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final root = result.root;
    final rows = _tree.rows;
    final extent = rowExtentFor(appSettings.density);
    final canSync = result.leftWritable || result.rightWritable;

    return Column(
      children: [
        StatsHeader(root: root, palette: palette),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Expand all (${AppAction.expandAll.keyLabel})',
                visualDensity: VisualDensity.compact,
                onPressed: () => _setAllExpanded(true),
                icon: const Icon(Icons.unfold_more, size: 19),
              ),
              IconButton(
                tooltip: 'Collapse all (${AppAction.collapseAll.keyLabel})',
                visualDensity: VisualDensity.compact,
                onPressed: () => _setAllExpanded(false),
                icon: const Icon(Icons.unfold_less, size: 19),
              ),
              const SizedBox(width: 10),
              SegmentedButton<TreeFilter>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: TreeFilter.all, label: Text('All')),
                  ButtonSegment(
                      value: TreeFilter.changes, label: Text('Changes')),
                  ButtonSegment(
                      value: TreeFilter.leftOnly, label: Text('Left only')),
                  ButtonSegment(
                      value: TreeFilter.rightOnly, label: Text('Right only')),
                ],
                selected: {_tree.filter},
                onSelectionChanged: (selection) => setState(() {
                  _tree.filter = selection.first;
                  _keepSelection();
                }),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'Ignore rules for this comparison',
                child: ActionChip(
                  avatar: const Icon(Icons.visibility_off_outlined, size: 16),
                  label: Text('${formatCount(result.ignoredCount)} ignored'),
                  visualDensity: VisualDensity.compact,
                  onPressed: _editIgnores,
                ),
              ),
              if (result.issues.isNotEmpty) ...[
                const SizedBox(width: 6),
                ActionChip(
                  avatar: Icon(Icons.warning_amber_rounded,
                      size: 16, color: palette.modified),
                  label: Text(
                      '${formatCount(result.issues.length)} unreadable'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showIssues(result),
                ),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: TextField(
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        hintText: 'Filter by name…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (value) => setState(() {
                        _tree.query = value;
                        _keepSelection();
                      }),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: canSync
                    ? 'Synchronize folders (${AppAction.syncFolders.keyLabel})'
                    : 'Both sides are read-only',
                child: FilledButton.tonalIcon(
                  onPressed: canSync && !_busy ? _synchronize : null,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Synchronize…'),
                ),
              ),
              const SizedBox(width: 4),
              MenuAnchor(
                menuChildren: _entryMenu(result),
                builder: (context, controller, _) {
                  final count = _selected.length;
                  return IconButton(
                    tooltip: count > 1
                        ? 'Actions for $count selected entries'
                        : 'Actions for the selected entry',
                    onPressed: _targets.isEmpty
                        ? null
                        : () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                    icon: Badge(
                      isLabelVisible: count > 1,
                      label: Text(formatCount(count)),
                      child: const Icon(Icons.more_vert, size: 20),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(),
        FolderColumnHeaders(
          sort: _tree.sort,
          onSort: (sort) => setState(() => _tree.sort = sort),
        ),
        const Divider(),
        Expanded(
          child: Stack(
            children: [
              // The focus and menu wrap the empty state too, so the
              // keyboard keeps working when a filter hides every row.
              Positioned.fill(
                child: Focus(
                  focusNode: _treeFocus,
                  onKeyEvent: _onTreeKey,
                  child: MenuAnchor(
                    controller: _menu,
                    childFocusNode: _treeFocus,
                    menuChildren: _entryMenu(result),
                    child: rows.isEmpty
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _treeFocus.requestFocus,
                            child: Center(
                              child: Text(
                                _tree.filter == TreeFilter.changes &&
                                        !_tree.searching &&
                                        !root.hasChanges
                                    ? 'Folders are identical 🎉'
                                    : 'Nothing matches the current filter.',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                        color: scheme.onSurfaceVariant),
                              ),
                            ),
                          )
                        : _treeView(rows, extent, palette),
                  ),
                ),
              ),
              if (_scan != null) ...[
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Center(
                    child: RescanToast(
                      progress: _progress,
                      started: _scanStarted,
                      onCancel: _cancelScan,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _treeView(List<TreeRow> rows, double extent, DiffPalette palette) {
    final focused = _treeFocus.hasFocus;
    final dateStyle = appSettings.dateStyle;
    final compact = appSettings.density == UiDensity.compact;
    return ListView.builder(
      key: _treeKey,
      controller: _scroll,
      itemCount: rows.length,
      itemExtent: extent,
      itemBuilder: (context, index) {
        final row = rows[index];
        final node = row.node;
        final path = node.relativePath;
        return FolderTreeRow(
          key: ValueKey(path),
          node: node,
          depth: row.depth,
          palette: palette,
          expanded: _tree.isExpanded(node),
          selected: _selected.contains(path),
          cursor: _cursor == path,
          focused: focused,
          dateStyle: dateStyle,
          compact: compact,
          onTapDown: (_) => _onRowTapDown(node),
          onSecondaryTapDown: (details) =>
              _onRowSecondaryTapDown(node, details),
        );
      },
    );
  }

  /// The actions for the selected entries, for the context menu and the
  /// toolbar's menu button.
  List<Widget> _entryMenu(ScanResult result) {
    final targets = _targets;
    final single = targets.length == 1 ? targets.single : null;
    final idle = !_busy;
    bool canCopy(Side from) =>
        idle &&
        result.writable(from.other) &&
        targets.any((n) => n.existsOn(from) && n.hasChanges);
    bool canDelete(Side side) =>
        idle &&
        result.writable(side) &&
        targets.any((n) => n.existsOn(side) && n.relativePath.isNotEmpty);
    final many = targets.length > 1 ? ' (${formatCount(targets.length)})' : '';

    List<Widget> sideMenu(Side side) {
      final node = single != null && single.existsOn(side) ? single : null;
      return [
        MenuItemButton(
          leadingIcon: const Icon(Icons.content_copy, size: 18),
          onPressed: node == null ? null : () => _copyPath(side, node),
          child: const Text('Copy path'),
        ),
        // Only offered where the side has paths on this machine.
        if (result.isLocal(side)) ...[
          MenuItemButton(
            leadingIcon: const Icon(Icons.folder_open_outlined, size: 18),
            onPressed:
                node == null ? null : () => _showInFileManager(side, node),
            child: const Text('Show in file manager'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.edit_note, size: 18),
            onPressed: node == null ? null : () => _openInEditor(side, node),
            child: Text(appSettings.externalEditor.trim().isEmpty
                ? 'Open with default app'
                : 'Open in external editor'),
          ),
        ],
      ];
    }

    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.open_in_new, size: 18),
        shortcut: AppAction.openEntry.activator,
        onPressed: single == null ? null : () => _openComparison(single),
        child: Text(single?.isDirectory == true
            ? 'Open folder comparison'
            : 'Open comparison'),
      ),
      const Divider(height: 8),
      MenuItemButton(
        leadingIcon: const Icon(Icons.arrow_forward, size: 18),
        onPressed: canCopy(Side.left) ? () => _copy(Side.left) : null,
        child: Text('Copy to right$many'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.arrow_back, size: 18),
        onPressed: canCopy(Side.right) ? () => _copy(Side.right) : null,
        child: Text('Copy to left$many'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.delete_outline, size: 18),
        onPressed: canDelete(Side.left) ? () => _delete(Side.left) : null,
        child: Text('Delete on left$many…'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.delete_outline, size: 18),
        onPressed: canDelete(Side.right) ? () => _delete(Side.right) : null,
        child: Text('Delete on right$many…'),
      ),
      const Divider(height: 8),
      SubmenuButton(
        leadingIcon: const Icon(Icons.west, size: 18),
        menuChildren: sideMenu(Side.left),
        child: const Text('Left side'),
      ),
      SubmenuButton(
        leadingIcon: const Icon(Icons.east, size: 18),
        menuChildren: sideMenu(Side.right),
        child: const Text('Right side'),
      ),
      const Divider(height: 8),
      MenuItemButton(
        leadingIcon: const Icon(Icons.visibility_off_outlined, size: 18),
        onPressed: targets.any((n) => n.relativePath.isNotEmpty)
            ? _ignoreTargets
            : null,
        child: Text(single != null
            ? 'Ignore “${single.name}” in this comparison'
            : 'Ignore$many in this comparison'),
      ),
    ];
  }
}
