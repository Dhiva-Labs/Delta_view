/// Two-way text comparison, Meld-style: aligned rows with folding, wrap
/// and syntax colours in view mode; two editors with aligned scrolling in
/// edit mode; copying changes across in either, with undo; and saving in
/// the encoding and line endings each file came with.
///
/// The pieces live in file_diff/: [DiffSession] holds the texts, diff,
/// history and search; [DiffRowsView] and [DiffEditorsView] draw the two
/// modes; this widget is the toolbar, headers, status bar and the glue.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../compare/diff_side.dart';
import '../diff/line_diff.dart';
import '../diff/unified_diff.dart';
import '../settings/app_settings.dart';
import '../theme.dart';
import 'file_diff/connector_gutter.dart';
import 'file_diff/dialogs.dart';
import 'file_diff/diff_session.dart';
import 'file_diff/editors_view.dart';
import 'file_diff/find_bar.dart';
import 'file_diff/line_layout.dart';
import 'file_diff/minimap.dart';
import 'file_diff/rows_view.dart';
import 'file_diff/rules_menu.dart';
import 'file_diff/status_bar.dart';
import 'file_diff/viewport.dart';
import 'shell.dart';
import 'shortcuts/app_shortcuts.dart';

/// The text size "Reset text size" returns to: the settings default.
final _defaultFontSize = AppSettings().editorFontSize;

class FileDiffView extends StatefulWidget {
  const FileDiffView({
    super.key,
    required this.left,
    required this.right,
    this.title,
    this.onBack,
    this.startEditing = false,
  });

  final DiffSide left;
  final DiffSide right;
  final String? title;
  final VoidCallback? onBack;

  /// Open in edit mode (e.g. an empty clipboard compare waiting for text).
  final bool startEditing;

  @override
  State<FileDiffView> createState() => _FileDiffViewState();
}

class _FileDiffViewState extends State<FileDiffView> {
  late final DiffSession _session = DiffSession(widget.left, widget.right,
      options: appSettings.compareOptions);
  late bool _editing = widget.startEditing;

  /// The change last jumped to or clicked, or -1.
  int _currentBlock = -1;

  final _rowsKey = GlobalKey<DiffRowsViewState>();
  final _editorsKey = GlobalKey<DiffEditorsViewState>();
  final _rowsScroll = ScrollController();
  final _editScrolls = [ScrollController(), ScrollController()];
  final _viewFocus = FocusNode(debugLabel: 'file diff view');
  final _findFocus = FocusNode(debugLabel: 'find in files');
  bool _findOpen = false;
  String _lastQuery = '';

  /// Caret of the focused editor: (side, line, column), all 0-based.
  final _cursor = ValueNotifier<(int, int, int)?>(null);
  int _lastFocusedSide = 0;

  /// Ticks when the panes have laid out lines anew, so what depends on
  /// their positions (previous / next, "change N of M") updates.
  final _layoutTick = ValueNotifier<int>(0);
  void _onLayout() => _layoutTick.value++;

  int? _flashRow;
  Timer? _flashTimer;

  TabHandle? _tab;
  bool _reportedDirty = false;

  DiffViewport? get _viewport =>
      _editing ? _editorsKey.currentState : _rowsKey.currentState;

  List<SideModel> get _sides => _session.sides;

  @override
  void initState() {
    super.initState();
    _session
      ..addListener(_onSession)
      ..onNotify = _toast;
    appSettings.addListener(_onSettings);
    for (var i = 0; i < 2; i++) {
      final side = _sides[i];
      side.controller.addListener(() => _updateCursor(i));
      side.focusNode.addListener(() {
        if (side.focusNode.hasFocus) _lastFocusedSide = i;
        _updateCursor(i);
      });
    }
    _load();
  }

  Future<void> _load() async {
    await _session.load();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_editing) {
        _sides[0].focusNode.requestFocus();
      } else {
        _focusView();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tab ??= TabScope.maybeOf(context);
  }

  @override
  void dispose() {
    _tab?.setCloseGuard(null);
    if (_reportedDirty) {
      // The tab may stay open (back to the picker); it is no longer dirty.
      // Not now: the shell cannot rebuild while this tree is torn down.
      final tab = _tab;
      WidgetsBinding.instance.addPostFrameCallback((_) => tab?.setDirty(false));
    }
    appSettings.removeListener(_onSettings);
    _session
      ..removeListener(_onSession)
      ..dispose();
    _rowsScroll.dispose();
    for (final s in _editScrolls) {
      s.dispose();
    }
    _viewFocus.dispose();
    _findFocus.dispose();
    _cursor.dispose();
    _layoutTick.dispose();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final dirty = _session.dirty;
    if (dirty != _reportedDirty) {
      _reportedDirty = dirty;
      _tab?.setDirty(dirty);
      // Guard only while there is something to lose, so quitting does not
      // stop at every clean tab.
      _tab?.setCloseGuard(dirty ? _confirmClose : null);
    }
    if (_currentBlock >= _session.blocks.length) {
      _currentBlock = _session.blocks.length - 1;
    }
    setState(() {});
  }

  void _onSettings() {
    if (!mounted) return;
    if (!_session.optionsOverridden &&
        _session.options != appSettings.compareOptions) {
      _session.setOptions(appSettings.compareOptions, overridden: false);
    }
    setState(() {});
  }

  void _updateCursor(int side) {
    final model = _sides[side];
    if (!_editing || !model.focusNode.hasFocus) {
      if (_cursor.value?.$1 == side && !model.focusNode.hasFocus) {
        _cursor.value = null;
      }
      return;
    }
    final offset = model.controller.selection.extentOffset;
    if (offset < 0) return;
    final line = _session.lineAt(side, offset);
    final starts = _session.lineStarts(side);
    final start = line < starts.length ? starts[line] : model.text.length;
    _cursor.value = (side, line, offset - start);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        width: 420,
      ));
  }

  void _focusView() {
    if (!_viewFocus.hasFocus) _viewFocus.requestFocus();
  }

  // ---- navigation ----

  void _step(int direction) {
    final viewport = _viewport;
    if (viewport == null) return;
    final next = neighbourBlock(
        viewport, _session.blocks.length, _currentBlock, direction);
    if (next == null) return;
    setState(() => _currentBlock = next);
    viewport.revealBlock(next);
  }

  void _onRowTap(int row) {
    _focusView();
    final blocks = _session.blocks;
    final i = blocks.indexWhere((b) => b.containsRow(row));
    if (i >= 0 && i != _currentBlock) setState(() => _currentBlock = i);
  }

  /// The block keyboard copy acts on: the one under the caret in edit
  /// mode, else the current one while on screen, else the first visible.
  int? _targetBlock() {
    if (_editing) {
      final atCursor = _editorsKey.currentState?.blockAtCursor();
      if (atCursor != null) return atCursor;
    }
    final viewport = _viewport;
    final count = _session.blocks.length;
    if (viewport == null || count == 0) return null;
    final top = viewport.scrollTop, bottom = top + viewport.viewHeight;
    bool onScreen(int i) {
      final y = viewport.blockTop(i);
      return y >= top - 1 && y <= bottom;
    }

    if (_currentBlock >= 0 &&
        _currentBlock < count &&
        onScreen(_currentBlock)) {
      return _currentBlock;
    }
    for (var i = 0; i < count; i++) {
      if (onScreen(i)) return i;
      if (viewport.blockTop(i) > bottom) break;
    }
    return null;
  }

  Future<void> _copy(int index, {required bool toRight}) async {
    if (await _session.copyBlock(index, toRight: toRight) && mounted) {
      // The copied change is gone; the index now names the next one.
      setState(() =>
          _currentBlock = index.clamp(-1, _session.blocks.length - 1).toInt());
    }
  }

  Future<void> _delete(int index, {required bool left}) async {
    await _session.deleteBlock(index, left: left);
  }

  void _copyCurrent({required bool toRight}) {
    final target = _targetBlock();
    if (target != null) _copy(target, toRight: toRight);
  }

  // ---- edit / view ----

  void _setEditing(bool editing) {
    if (editing == _editing) return;
    // Keep the same lines in view across the switch.
    int? leftLine;
    if (_editing) {
      leftLine = _editorsKey.currentState?.topLine(0).floor();
    } else {
      final rows = _rowsKey.currentState;
      if (rows != null) leftLine = _leftLineAtRow(rows.topRow);
    }
    setState(() => _editing = editing);
    _cursor.value = null;
    if (!editing) _session.rediff();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || leftLine == null) return;
      if (editing) {
        _editorsKey.currentState
            ?.revealLine(0, leftLine, animate: false, margin: 0);
      } else {
        final rowOf = _session.rowOfLine[0];
        if (leftLine < rowOf.length) {
          _rowsKey.currentState
              ?.revealRow(rowOf[leftLine], animate: false, margin: 0);
        }
        _focusView();
      }
    });
  }

  /// The left line shown at [row], or the next one down.
  int _leftLineAtRow(int row) {
    final rows = _session.result?.rows ?? const <DiffRow>[];
    for (var i = row; i < rows.length; i++) {
      final n = rows[i].leftNumber;
      if (n != null) return n - 1;
    }
    return 0;
  }

  /// Runs [change] (which re-lays out the text) keeping the line at the
  /// top in place.
  void _keepPosition(VoidCallback change) {
    final editing = _editing;
    final top = editing
        ? _editorsKey.currentState?.topLine(0).floor()
        : _rowsKey.currentState?.topRow;
    change();
    if (top == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || editing != _editing) return;
      if (editing) {
        _editorsKey.currentState?.revealLine(0, top, animate: false, margin: 0);
      } else {
        _rowsKey.currentState?.revealRow(top, animate: false, margin: 0);
      }
    });
  }

  void _toggleWrap() => _keepPosition(() {
        appSettings.wordWrap = !appSettings.wordWrap;
        appSettings.changed();
      });

  void _toggleFold() => _keepPosition(() {
        appSettings.foldUnchanged = !appSettings.foldUnchanged;
        appSettings.changed();
      });

  void _zoom(int direction) {
    final size = direction == 0
        ? _defaultFontSize
        : (appSettings.editorFontSize + direction).clamp(8.0, 32.0);
    if (size == appSettings.editorFontSize) return;
    _keepPosition(() {
      appSettings.editorFontSize = size.toDouble();
      appSettings.changed();
    });
  }

  // ---- undo ----

  /// Undo and redo act on the comparison, except in the search field,
  /// which keeps its own.
  void _undo() {
    if (_findFocus.hasFocus) {
      Actions.maybeInvoke(_findFocus.context!,
          const UndoTextIntent(SelectionChangedCause.keyboard));
      return;
    }
    _session.undo();
  }

  void _redo() {
    if (_findFocus.hasFocus) {
      Actions.maybeInvoke(_findFocus.context!,
          const RedoTextIntent(SelectionChangedCause.keyboard));
      return;
    }
    _session.redo();
  }

  // ---- search ----

  void _openFind() {
    final selected = _selectedText();
    setState(() => _findOpen = true);
    if (selected != null) {
      _session.setQuery(selected);
    } else if (_session.query.isEmpty && _lastQuery.isNotEmpty) {
      _session.setQuery(_lastQuery);
    }
    _startSearchFromView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocus.requestFocus();
    });
  }

  /// A short single-line selection in the focused editor seeds the search.
  String? _selectedText() {
    if (!_editing) return null;
    final model = _sides[_lastFocusedSide];
    final selection = model.controller.selection;
    if (!selection.isValid || selection.isCollapsed) return null;
    final text = selection.textInside(model.text);
    return text.contains('\n') || text.length > 200 ? null : text;
  }

  void _closeFind() {
    _lastQuery = _session.query;
    _session.setQuery('');
    setState(() => _findOpen = false);
    if (_editing) {
      _sides[_lastFocusedSide].focusNode.requestFocus();
    } else {
      _focusView();
    }
  }

  void _onQuery(String query) {
    _session.setQuery(query);
    _startSearchFromView();
  }

  /// Makes the first hit at or below the top of the view the current one.
  void _startSearchFromView() {
    if (_session.matches.isEmpty) return;
    int row;
    if (_editing) {
      final line = _editorsKey.currentState?.topLine(0).floor() ?? 0;
      final rowOf = _session.rowOfLine[0];
      row = rowOf.isEmpty ? 0 : rowOf[line.clamp(0, rowOf.length - 1)];
    } else {
      row = _rowsKey.currentState?.topRow ?? 0;
    }
    _session.selectMatchFromRow(row);
    _revealMatch();
  }

  void _stepMatch(int direction) {
    if (!_findOpen) {
      if (_lastQuery.isEmpty) return;
      _openFind();
      return;
    }
    _session.stepMatch(direction);
    _revealMatch();
  }

  void _revealMatch() {
    final m = _session.currentFindMatch;
    if (m == null) return;
    if (_editing) {
      _editorsKey.currentState?.revealLine(m.side, m.line,
          select: TextSelection(
              baseOffset: m.offset, extentOffset: m.offset + m.end - m.start));
      return;
    }
    final rows = _rowsKey.currentState;
    final rowOf = _session.rowOfLine[m.side];
    if (rows == null || m.line >= rowOf.length) return;
    final row = rowOf[m.line];
    rows.revealRow(row, center: true);
    final diffRow = _session.result!.rows[row];
    final text = (m.side == 0 ? diffRow.leftText : diffRow.rightText) ?? '';
    rows.revealColumns(
        text, m.start.clamp(0, text.length), m.end.clamp(0, text.length));
  }

  // ---- go to line ----

  Future<void> _goToLine() async {
    final answer = await askGoToLine(
      context,
      left: !_editing || _lastFocusedSide == 0,
      leftLines: _session.lineCount(0),
      rightLines: _session.lineCount(1),
    );
    if (answer == null || !mounted) return;
    final (left, line) = answer;
    final side = left ? 0 : 1;
    if (_editing) {
      final starts = _session.lineStarts(side);
      final offset = starts[(line - 1).clamp(0, starts.length - 1)];
      _editorsKey.currentState?.revealLine(side, line - 1,
          select: TextSelection.collapsed(offset: offset), focus: true);
      return;
    }
    final rowOf = _session.rowOfLine[side];
    if (line - 1 >= rowOf.length) return;
    final row = rowOf[line - 1];
    _rowsKey.currentState?.revealRow(row, center: true);
    setState(() => _flashRow = row);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _flashRow = null);
    });
  }

  // ---- saving ----

  Future<void> _saveAll() async {
    final dirty = [
      for (var i = 0; i < 2; i++)
        if (_sides[i].dirty) i
    ];
    if (dirty.isEmpty) {
      _toast('No unsaved changes');
      return;
    }
    for (final i in dirty) {
      if (!await _saveSide(i)) return;
    }
  }

  /// Saves one side in place, or with "Save as" when it has no place of
  /// its own (pasted text, archives). False when cancelled or failed.
  Future<bool> _saveSide(int side) async {
    final model = _sides[side];
    if (!model.canSaveInPlace) return _saveSideAs(side);
    if (!await _ensureEncodable(side)) return false;
    try {
      await _session.save(side);
      _toast('Saved ${model.label}');
      return true;
    } catch (e) {
      _toast('Could not save ${model.label}: $e');
      return false;
    }
  }

  Future<bool> _saveSideAs(int side) async {
    final model = _sides[side];
    final current = model.side.localPath;
    final location = await getSaveLocation(
      suggestedName:
          model.isMemory ? (side == 0 ? 'left.txt' : 'right.txt') : model.label,
      initialDirectory: current == null ? null : p.dirname(current),
      confirmButtonText: 'Save',
    );
    if (location == null || !mounted) return false;
    if (!await _ensureEncodable(side)) return false;
    try {
      await _session.saveAs(side, location.path);
      _toast('Saved ${p.basename(location.path)}');
      return true;
    } catch (e) {
      _toast('Could not save: $e');
      return false;
    }
  }

  /// When the side's encoding cannot hold its text, asks to switch to
  /// UTF-8 rather than writing something else than what is on screen.
  Future<bool> _ensureEncodable(int side) async {
    final model = _sides[side];
    final bad = firstUnencodable(model.text, model.format.encoding);
    if (bad == null) return true;
    final char = String.fromCharCode(model.text.codeUnitAt(bad));
    if (!await askSaveAsUtf8(context, model.label, char)) return false;
    _session.setFormat(
        side, model.format.copyWith(encoding: TextEncoding.utf8, bom: false));
    return true;
  }

  /// The tab's close guard: offers to save unsaved sides.
  Future<bool> _confirmClose() async {
    final dirty = [
      for (var i = 0; i < 2; i++)
        if (_sides[i].dirty) i
    ];
    if (dirty.isEmpty || !mounted) return true;
    final choice =
        await askSaveChanges(context, [for (final i in dirty) _sides[i].label]);
    switch (choice) {
      case SaveChoice.save:
        for (final i in dirty) {
          if (!await _saveSide(i)) return false;
        }
        return true;
      case SaveChoice.discard:
        return true;
      case SaveChoice.cancel:
        return false;
    }
  }

  Future<void> _back() async {
    if (await _confirmClose()) widget.onBack?.call();
  }

  Future<void> _refresh() async {
    final dirty = [
      for (final s in _sides)
        if (s.dirty && !s.isMemory) s.label
    ];
    if (dirty.isNotEmpty && !await askDiscardAndReload(context, dirty)) return;
    await _session.reloadAll();
    if (_sides.any((s) => !s.isMemory)) _toast('Compared again from disk');
  }

  Future<void> _paste(int side) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _toast('The clipboard has no text');
      return;
    }
    final decoded = decodeString(text);
    _session.replaceText(side, decoded.text, label: 'Paste');
    if (decoded.format.lineEnding != _sides[side].format.lineEnding) {
      _session.setFormat(side,
          _sides[side].format.copyWith(lineEnding: decoded.format.lineEnding));
    }
  }

  // ---- export ----

  String _patch() {
    String raw(SideModel s) =>
        applyLineEndings(s.text, s.format.lineEnding, mixed: s.mixed);
    return unifiedDiff(
      raw(_sides[0]),
      raw(_sides[1]),
      leftName: _sides[0].side.description,
      rightName: _sides[1].side.description,
      options: _session.options,
    );
  }

  Future<void> _copyPatch() async {
    final patch = _patch();
    if (patch.isEmpty) {
      _toast('No differences to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: patch));
    _toast('Copied the unified diff');
  }

  Future<void> _savePatch() async {
    final patch = _patch();
    if (patch.isEmpty) {
      _toast('No differences to save');
      return;
    }
    final base = p.basenameWithoutExtension(_sides[0].label);
    final location = await getSaveLocation(
      suggestedName: '${base.isEmpty ? 'changes' : base}.patch',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Patch', extensions: ['patch', 'diff']),
      ],
      confirmButtonText: 'Save',
    );
    if (location == null) return;
    try {
      await File(location.path).writeAsString(patch, flush: true);
      _toast('Saved ${p.basename(location.path)}');
    } catch (e) {
      _toast('Could not save the patch: $e');
    }
  }

  Future<void> _copyText(int side) async {
    await Clipboard.setData(ClipboardData(text: _sides[side].text));
    _toast('Copied the ${side == 0 ? 'left' : 'right'} text');
  }

  // ---- keys ----

  /// Scrolling keys in view mode (editors handle their own).
  KeyEventResult _onViewKey(FocusNode node, KeyEvent event) {
    if (_editing || event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final rows = _rowsKey.currentState;
    if (rows == null) return KeyEventResult.ignored;
    final line = EditorMetrics.of(appSettings).lineHeight;
    final page = rows.viewHeight * 0.9;
    final ctrl = keyboard.isControlPressed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown when !ctrl:
        rows.scrollBy(line);
      case LogicalKeyboardKey.arrowUp when !ctrl:
        rows.scrollBy(-line);
      case LogicalKeyboardKey.pageDown:
        rows.scrollBy(page);
      case LogicalKeyboardKey.pageUp:
        rows.scrollBy(-page);
      case LogicalKeyboardKey.home:
        rows.scrollBy(-double.maxFinite);
      case LogicalKeyboardKey.end:
        rows.scrollBy(double.maxFinite);
      case LogicalKeyboardKey.arrowLeft when !ctrl:
        rows.scrollHorizontallyBy(-40);
      case LogicalKeyboardKey.arrowRight when !ctrl:
        rows.scrollHorizontallyBy(40);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---- build ----

  String get _title =>
      widget.title ?? '${_sides[0].label} ↔ ${_sides[1].label}';

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session.error != null) {
      return Center(child: Text('Could not read files:\n${session.error}'));
    }
    if (session.notice != null) return _NoticeView(message: session.notice!);
    final result = session.result;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final metrics = EditorMetrics.of(appSettings);

    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.nextChange: () => _step(1),
        AppAction.previousChange: () => _step(-1),
        AppAction.find: _openFind,
        AppAction.findNext: () => _stepMatch(1),
        AppAction.findPrevious: () => _stepMatch(-1),
        AppAction.goToLine: _goToLine,
        AppAction.save: _saveAll,
        AppAction.toggleEdit: () => _setEditing(!_editing),
        AppAction.copyToRight: () => _copyCurrent(toRight: true),
        AppAction.copyToLeft: () => _copyCurrent(toRight: false),
        AppAction.undo: _undo,
        AppAction.redo: _redo,
        AppAction.zoomIn: () => _zoom(1),
        AppAction.zoomOut: () => _zoom(-1),
        AppAction.zoomReset: () => _zoom(0),
        AppAction.toggleWrap: _toggleWrap,
        AppAction.toggleFold: _toggleFold,
        AppAction.refresh: _refresh,
      }),
      child: Listener(
        // Clicks anywhere bring the keyboard here, unless an editor or
        // field inside already has it.
        onPointerDown: (_) {
          final focus = FocusManager.instance.primaryFocus;
          if (focus == null || !_isInside(focus)) _focusView();
        },
        child: Column(
          children: [
            _toolbar(context, result),
            for (var i = 0; i < 2; i++)
              if (_sides[i].pendingDiskBytes != null) _diskBanner(context, i),
            _paneHeaders(context),
            const Divider(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Focus(
                      focusNode: _viewFocus,
                      onKeyEvent: _onViewKey,
                      child: _editing
                          ? DiffEditorsView(
                              key: _editorsKey,
                              session: session,
                              scrolls: _editScrolls,
                              metrics: metrics,
                              currentBlock: _currentBlock,
                              onCopy: _copy,
                              onDelete: _delete,
                              onLayout: _onLayout,
                            )
                          : DiffRowsView(
                              key: _rowsKey,
                              session: session,
                              scroll: _rowsScroll,
                              metrics: metrics,
                              fold: appSettings.foldUnchanged,
                              foldContext: appSettings.foldContext,
                              currentBlock: _currentBlock,
                              onCopy: _copy,
                              onDelete: _delete,
                              onRowTap: _onRowTap,
                              highlightRow: _flashRow,
                              onLayout: _onLayout,
                            ),
                    ),
                  ),
                  if (_findOpen)
                    Positioned(
                      top: 8,
                      right: Minimap.width + 12,
                      child: FindBar(
                        session: session,
                        focusNode: _findFocus,
                        onQueryChanged: _onQuery,
                        onStep: _stepMatch,
                        onClose: _closeFind,
                      ),
                    ),
                ],
              ),
            ),
            _statusBar(),
          ],
        ),
      ),
    );
  }

  bool _isInside(FocusNode node) {
    final viewContext = _viewFocus.context;
    if (viewContext == null) return false;
    if (node == _viewFocus || node == _findFocus) return true;
    if (_sides.any((s) => s.focusNode == node)) return true;
    return node.ancestors.contains(_viewFocus);
  }

  /// Below these widths the toolbar sheds labels, then moves undo and redo
  /// into the overflow menu, rather than overflowing.
  static const _compactToolbar = 1000.0;
  static const _narrowToolbar = 820.0;

  Widget _toolbar(BuildContext context, DiffResult result) {
    return LayoutBuilder(
        builder: (context, constraints) => _toolbarRow(context, result,
            compact: constraints.maxWidth < _compactToolbar,
            narrow: constraints.maxWidth < _narrowToolbar));
  }

  Widget _toolbarRow(BuildContext context, DiffResult result,
      {required bool compact, required bool narrow}) {
    final palette = DiffPalette.of(context);
    final history = _session.history;
    String tip(String label, AppAction action) => '$label (${action.keyLabel})';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Change files',
              onPressed: _back,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 14),
          _ChangeStats(result: result, palette: palette),
          if (_session.dirty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('● unsaved',
                  style: TextStyle(fontSize: 11.5, color: palette.modified)),
            ),
          const Spacer(),
          IconButton(
            tooltip: tip('Find', AppAction.find),
            isSelected: _findOpen,
            onPressed: _findOpen ? _closeFind : _openFind,
            icon: const Icon(Icons.search, size: 20),
          ),
          _navigation(),
          if (!compact) const _ToolbarDivider(),
          if (!narrow) ...[
            IconButton(
              tooltip: history.canUndo
                  ? tip('Undo ${history.undoLabel!.toLowerCase()}',
                      AppAction.undo)
                  : tip('Undo', AppAction.undo),
              onPressed: history.canUndo ? _session.undo : null,
              icon: const Icon(Icons.undo, size: 20),
            ),
            IconButton(
              tooltip: history.canRedo
                  ? tip('Redo ${history.redoLabel!.toLowerCase()}',
                      AppAction.redo)
                  : tip('Redo', AppAction.redo),
              onPressed: history.canRedo ? _session.redo : null,
              icon: const Icon(Icons.redo, size: 20),
            ),
          ],
          if (!compact) const _ToolbarDivider(),
          IconButton(
            tooltip: tip('Wrap long lines', AppAction.toggleWrap),
            isSelected: appSettings.wordWrap,
            onPressed: _toggleWrap,
            icon: const Icon(Icons.wrap_text, size: 20),
          ),
          IconButton(
            tooltip: _editing
                ? 'Hiding unchanged lines works in view mode'
                : tip('Hide unchanged lines', AppAction.toggleFold),
            isSelected: appSettings.foldUnchanged,
            onPressed: _editing ? null : _toggleFold,
            icon: const Icon(Icons.unfold_less, size: 20),
          ),
          CompareRulesButton(
            options: _session.options,
            overridden: _session.optionsOverridden,
            onChanged: _session.setOptions,
            onReset: () => _session.setOptions(appSettings.compareOptions,
                overridden: false),
          ),
          _moreMenu(withUndo: narrow),
          const SizedBox(width: 6),
          Tooltip(
            message: tip('Switch between view and edit', AppAction.toggleEdit),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: compact ? null : const Text('View')),
                ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: compact ? null : const Text('Edit')),
              ],
              selected: {_editing},
              onSelectionChanged: (selection) => _setEditing(selection.first),
            ),
          ),
        ],
      ),
    );
  }

  /// Previous / next change, enabled by where the panes are scrolled.
  Widget _navigation() {
    return ListenableBuilder(
      listenable: Listenable.merge([_rowsScroll, _editScrolls[0], _layoutTick]),
      builder: (context, _) {
        final count = _session.blocks.length;
        final vp = _viewport;
        final previous =
            vp == null ? null : neighbourBlock(vp, count, _currentBlock, -1);
        final next = vp == null
            ? (count > 0 ? 0 : null)
            : neighbourBlock(vp, count, _currentBlock, 1);
        return Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Previous change (${AppAction.previousChange.keyLabel})',
            onPressed: previous == null ? null : () => _step(-1),
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: 'Next change (${AppAction.nextChange.keyLabel})',
            onPressed: next == null ? null : () => _step(1),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
        ]);
      },
    );
  }

  Widget _moreMenu({required bool withUndo}) {
    PopupMenuItem<VoidCallback> item(
            IconData icon, String label, VoidCallback action,
            {AppAction? keys, bool enabled = true}) =>
        PopupMenuItem(
          value: action,
          enabled: enabled,
          child: Row(children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
            if (keys != null)
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text(keys.keyLabel,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
          ]),
        );
    final identical = _session.blocks.isEmpty;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        if (withUndo) ...[
          item(Icons.undo, 'Undo', _session.undo,
              keys: AppAction.undo, enabled: _session.history.canUndo),
          item(Icons.redo, 'Redo', _session.redo,
              keys: AppAction.redo, enabled: _session.history.canRedo),
          const PopupMenuDivider(),
        ],
        item(Icons.content_copy, 'Copy as unified diff', _copyPatch,
            enabled: !identical),
        item(Icons.save_alt, 'Save patch…', _savePatch, enabled: !identical),
        const PopupMenuDivider(),
        item(Icons.west, 'Copy left text', () => _copyText(0)),
        item(Icons.east, 'Copy right text', () => _copyText(1)),
        const PopupMenuDivider(),
        item(Icons.refresh, 'Reload from disk', _refresh,
            keys: AppAction.refresh, enabled: _sides.any((s) => !s.isMemory)),
        item(Icons.pin_outlined, 'Go to line…', _goToLine,
            keys: AppAction.goToLine),
        const PopupMenuDivider(),
        item(Icons.zoom_in, 'Bigger text', () => _zoom(1),
            keys: AppAction.zoomIn),
        item(Icons.zoom_out, 'Smaller text', () => _zoom(-1),
            keys: AppAction.zoomOut),
        item(Icons.text_fields, 'Reset text size', () => _zoom(0),
            keys: AppAction.zoomReset),
      ],
    );
  }

  Widget _diskBanner(BuildContext context, int side) {
    final scheme = Theme.of(context).colorScheme;
    final model = _sides[side];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.sync_problem, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${model.label} changed on disk.',
              style: TextStyle(color: scheme.onTertiaryContainer)),
        ),
        TextButton(
          onPressed: () =>
              _session.reloadFromDisk(side, model.pendingDiskBytes!),
          child: const Text('Reload'),
        ),
        TextButton(
          onPressed: () => _session.keepMine(side),
          child: const Text('Keep mine'),
        ),
      ]),
    );
  }

  Widget _paneHeaders(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
      child: Row(children: [
        Expanded(child: _paneHeader(context, 0)),
        const SizedBox(width: ConnectorGutter.width),
        Expanded(child: _paneHeader(context, 1)),
        const SizedBox(width: Minimap.width),
      ]),
    );
  }

  Widget _paneHeader(BuildContext context, int side) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final model = _sides[side];
    final name = model.exists
        ? model.side.description
        : '${model.side.description}  (does not exist yet)';
    final saveLabel = !model.canSaveInPlace
        ? 'Save as…'
        : model.exists
            ? 'Save'
            : 'Create';
    final small = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontSize: 12),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 6),
      child: SizedBox(
        height: 30,
        child: Row(children: [
          if (model.dirty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.circle, size: 8, color: palette.modified),
            ),
          Expanded(
            child: Tooltip(
              message: name,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ),
          ),
          if (model.isMemory)
            Tooltip(
              message: 'Replace this side with the clipboard text',
              child: TextButton.icon(
                style: small,
                onPressed: () => _paste(side),
                icon: const Icon(Icons.content_paste, size: 15),
                label: const Text('Paste'),
              ),
            ),
          Tooltip(
            message: model.canSaveInPlace
                ? 'Save ${model.label} (${AppAction.save.keyLabel} saves both)'
                : 'Save to a file of your choice',
            child: TextButton.icon(
              style: small,
              onPressed:
                  model.dirty || (model.isMemory && model.text.isNotEmpty)
                      ? () => _saveSide(side)
                      : null,
              icon: const Icon(Icons.save_outlined, size: 15),
              label: Text(saveLabel),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statusBar() {
    SideStatus status(int i, (int, int, int)? cursor) => SideStatus(
          format: _sides[i].format,
          originalFormat: _sides[i].savedFormat,
          lines: _session.lineCount(i),
          canChangeFormat: true,
          cursor: cursor != null && cursor.$1 == i
              ? (cursor.$2 + 1, cursor.$3 + 1)
              : null,
        );
    final scroll =
        Listenable.merge([_rowsScroll, _editScrolls[0], _layoutTick]);
    return ValueListenableBuilder(
      valueListenable: _cursor,
      builder: (context, cursor, _) => DiffStatusBar(
        left: status(0, cursor),
        right: status(1, cursor),
        rules: _session.options.summary,
        onFormat: _session.setFormat,
        changeText: ListenableBuilder(
          listenable: scroll,
          builder: (context, _) {
            final count = _session.blocks.length;
            if (count == 0) return const Text('No differences');
            final viewport = _viewport;
            final at = viewport == null
                ? -1
                : blockAtReadingLine(viewport, count, _currentBlock);
            return Text(at < 0
                ? '$count change${count == 1 ? '' : 's'}'
                : 'Change ${at + 1} of $count');
          },
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 22,
        child: VerticalDivider(
          width: 12,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      );
}

class _ChangeStats extends StatelessWidget {
  const _ChangeStats({required this.result, required this.palette});

  final DiffResult result;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget chip(String text, Color color, String tooltip) => Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        );
    if (result.changeBlocks.isEmpty) {
      return chip(
          'identical',
          palette.added,
          'No differences under the '
              'current compare rules');
    }
    return Row(children: [
      if (result.addedCount > 0)
        chip('+${result.addedCount}', palette.added, 'Lines added'),
      if (result.removedCount > 0)
        chip('−${result.removedCount}', palette.removed, 'Lines removed'),
      if (result.modifiedCount > 0)
        chip('~${result.modifiedCount}', palette.modified, 'Lines changed'),
    ]);
  }
}

class _NoticeView extends StatelessWidget {
  const _NoticeView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.visibility_off_outlined,
              size: 42, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
