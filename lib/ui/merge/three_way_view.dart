import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';

import '../../compare/comparison.dart';
import '../../compare/diff_side.dart';
import '../../merge/merge_loader.dart';
import '../../theme.dart';
import '../shell.dart';
import '../shortcuts/app_shortcuts.dart';
import 'merge_dialogs.dart';
import 'merge_layout.dart';
import 'merge_rows.dart';

/// Three-way merge in Meld's layout: Left | Merged | Right, with the base
/// one click away. Clean changes are merged up front; each conflict is
/// resolved by taking a side, both sides, the base, or editing by hand.
///
/// Built to be opened by `git mergetool`: it shows up with the first
/// conflict selected and keyboard focus in place, so Alt+↓ / Alt+→ /
/// Alt+← / Ctrl+S resolve a typical merge without touching the mouse.
class ThreeWayMergeView extends StatefulWidget {
  const ThreeWayMergeView({super.key, required this.comparison, this.onBack});

  final ThreeWayComparison comparison;
  final VoidCallback? onBack;

  @override
  State<ThreeWayMergeView> createState() => _ThreeWayMergeViewState();
}

class _ThreeWayMergeViewState extends State<ThreeWayMergeView> {
  LoadedMerge? _loaded;
  Object? _error;

  /// Where saves go once known: the comparison's output, or the file the
  /// user picked the first time they saved.
  SourceSpec? _target;

  /// The document revision that matches the file on disk; null when none
  /// does (the merge has not been saved yet).
  int? _savedRevision;
  bool _saving = false;

  /// The chunk the toolbar and the keyboard act on.
  int? _selected;
  bool _showBase = false;

  int? _editing;
  int _editorLines = 1;
  List<String> _editorOriginal = const [];
  final _editor = TextEditingController();
  final _editorFocus = FocusNode(debugLabel: 'merge chunk editor');

  final _focus = FocusNode(debugLabel: 'merge view');
  final _scroll = ScrollController();
  TabHandle? _tab;
  bool _reportedDirty = false;

  MergeDocument? get _doc => _loaded?.document;

  bool get _dirty {
    final doc = _doc;
    return doc != null && doc.revision != _savedRevision;
  }

  MergeLabels get _labels => MergeLabels(
        left: widget.comparison.left.label,
        base: widget.comparison.base.label,
        right: widget.comparison.right.label,
      );

  @override
  void initState() {
    super.initState();
    _target = widget.comparison.output;
    _editor.addListener(_onEditorChanged);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tab = TabScope.maybeOf(context);
  }

  @override
  void dispose() {
    final tab = _tab;
    if (tab != null) {
      tab.setCloseGuard(null);
      // The shell rebuilds on setDirty, which it cannot do while this
      // subtree is being torn down.
      if (_reportedDirty) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => tab.setDirty(false),
        );
      }
    }
    _editor.dispose();
    _editorFocus.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- loading ----

  Future<void> _load() async {
    setState(() {
      _loaded = null;
      _error = null;
      _editing = null;
    });
    try {
      final loaded = await loadMerge(widget.comparison);
      if (!mounted) return;
      final doc = loaded.document;
      int? saved;
      if (widget.comparison.output != null) {
        final onDisk = loaded.outputBytes;
        if (onDisk != null &&
            listEquals(
              onDisk,
              loaded.format.encode(doc.resultLines(labels: _labels)),
            )) {
          saved = 0;
        }
      } else if (doc.changeIndexes.isEmpty) {
        saved = 0; // Nothing to merge, so nothing to save.
      }
      final targets = _navTargets(doc);
      setState(() {
        _loaded = loaded;
        _savedRevision = saved;
        _selected = doc.conflictIndexes
                .where((i) => !doc.state(i).isResolved)
                .firstOrNull ??
            targets.firstOrNull;
      });
      _syncTab();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        final selected = _selected;
        if (selected != null) _reveal(selected, animate: false);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _reload() async {
    if (_dirty && !await confirmReload(context)) return;
    await _load();
  }

  // ---- tab state ----

  void _syncTab() {
    final tab = _tab;
    if (tab == null) return;
    final dirty = _dirty;
    if (dirty != _reportedDirty) {
      _reportedDirty = dirty;
      tab.setDirty(dirty);
    }
    tab.setCloseGuard(dirty ? _confirmLeave : null);
  }

  /// Asks about unsaved work. True when it is fine to go.
  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    _commitEdit();
    final choice = await askUnsavedMerge(context, _name);
    return switch (choice) {
      null => false,
      UnsavedChoice.discard => true,
      UnsavedChoice.save => await _save(),
    };
  }

  Future<void> _back() async {
    if (await _confirmLeave()) widget.onBack?.call();
  }

  String get _name =>
      (widget.comparison.output ?? widget.comparison.base).label;

  // ---- actions ----

  void _changed({int? reveal}) {
    setState(() {});
    _syncTab();
    if (reveal != null) {
      setState(() => _selected = reveal);
      _reveal(reveal);
    }
  }

  void _select(int chunk) {
    if (_editing != null && _editing != chunk) _commitEdit();
    final doc = _doc;
    if (doc == null) return;
    final c = doc.chunks[chunk];
    final selectable =
        c.isChange || doc.state(chunk).resolution == Resolution.edited;
    setState(() => _selected = selectable ? chunk : null);
    _focus.requestFocus();
  }

  DateTime? _lastTap;
  int? _lastTapChunk;

  void _tapMerged(int chunk) {
    final now = DateTime.now();
    final last = _lastTap;
    if (_lastTapChunk == chunk &&
        last != null &&
        now.difference(last) < kDoubleTapTimeout) {
      _lastTap = null;
      _startEdit(chunk);
      return;
    }
    _lastTap = now;
    _lastTapChunk = chunk;
    _select(chunk);
  }

  void _take(int chunk, Resolution resolution) {
    _commitEdit();
    _doc?.take(chunk, resolution);
    setState(() => _selected = chunk);
    _changed();
  }

  void _append(int chunk, {required bool left}) {
    _commitEdit();
    _doc?.append(chunk, left: left);
    setState(() => _selected = chunk);
    _changed();
  }

  void _takeSelected(Resolution resolution) {
    final selected = _selected;
    if (selected != null) _take(selected, resolution);
  }

  void _appendSelected({required bool left}) {
    final selected = _selected;
    if (selected != null) _append(selected, left: left);
  }

  void _takeAll(Resolution resolution) {
    _commitEdit();
    _doc?.takeAllConflicts(resolution);
    _changed();
  }

  void _resetAll() {
    _commitEdit();
    _doc?.resetAll();
    _changed();
  }

  void _undo() {
    _commitEdit();
    final chunk = _doc?.undo();
    if (chunk != null) _changed(reveal: chunk);
  }

  void _redo() {
    _commitEdit();
    final chunk = _doc?.redo();
    if (chunk != null) _changed(reveal: chunk);
  }

  // ---- editing by hand ----

  void _startEdit(int chunk) {
    final doc = _doc;
    if (doc == null) return;
    if (_editing == chunk) return;
    _commitEdit();
    final state = doc.state(chunk);
    final lines = state.isResolved
        ? state.lines
        : doc.conflictMarkers(chunk, labels: _labels);
    _editorOriginal = lines;
    _editor.text = lines.join('\n');
    _editor.selection = const TextSelection.collapsed(offset: 0);
    setState(() {
      _editing = chunk;
      _selected = chunk;
      _editorLines = math.max(1, lines.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editing != chunk) return;
      _reveal(chunk);
      _editorFocus.requestFocus();
    });
  }

  void _onEditorChanged() {
    if (_editing == null) return;
    final lines = '\n'.allMatches(_editor.text).length + 1;
    if (lines != _editorLines) setState(() => _editorLines = lines);
  }

  void _commitEdit() {
    final chunk = _editing;
    final doc = _doc;
    if (chunk == null || doc == null) return;
    final text = _editor.text;
    final lines = text.isEmpty ? <String>[] : text.split('\n');
    setState(() => _editing = null);
    if (!listEquals(lines, _editorOriginal)) {
      doc.edit(chunk, lines);
      _syncTab();
    }
    _focus.requestFocus();
  }

  void _cancelEdit() {
    if (_editing == null) return;
    setState(() => _editing = null);
    _focus.requestFocus();
  }

  // ---- navigation ----

  /// Conflicts when there are any, otherwise every change.
  static List<int> _navTargets(MergeDocument doc) =>
      doc.conflictIndexes.isNotEmpty ? doc.conflictIndexes : doc.changeIndexes;

  int? _neighbour(int direction) {
    final doc = _doc;
    if (doc == null) return null;
    final targets = _navTargets(doc);
    if (targets.isEmpty) return null;
    final from = _selected ?? _chunkAtTop();
    if (from == null) return targets.first;
    if (direction > 0) {
      return targets.where((t) => t > from).firstOrNull ??
          (_selected == null ? targets.last : null);
    }
    return targets.where((t) => t < from).lastOrNull;
  }

  int? _chunkAtTop() {
    final doc = _doc;
    if (doc == null || doc.chunks.isEmpty || !_scroll.hasClients) return null;
    return _layout(doc).chunkAtOffset(_scroll.offset);
  }

  void _go(int direction) {
    final next = _neighbour(direction);
    if (next == null) return;
    _commitEdit();
    setState(() => _selected = next);
    _reveal(next);
  }

  /// Scrolls [chunk] into view, leaving some context above it.
  void _reveal(int chunk, {bool animate = true}) {
    final doc = _doc;
    if (doc == null || !_scroll.hasClients) return;
    final layout = _layout(doc);
    final position = _scroll.position;
    final top = layout.offsetOf(chunk);
    final bottom = top + layout.heightOf(chunk);
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    if (top >= viewTop + mergeRowExtent &&
        bottom <= viewBottom - mergeRowExtent) {
      return;
    }
    final target = (top - math.min(120.0, position.viewportDimension / 4))
        .clamp(0.0, position.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  // ---- saving ----

  /// Writes the merge. With [saveAs], asks for a new file first. Returns
  /// whether the merge was written.
  Future<bool> _save({bool saveAs = false}) async {
    _commitEdit();
    final doc = _doc;
    final loaded = _loaded;
    if (doc == null || loaded == null || _saving) return false;
    if (doc.unresolvedCount > 0 &&
        !await confirmSaveWithConflicts(context, doc.unresolvedCount)) {
      return false;
    }
    if (!mounted) return false;
    final output = widget.comparison.output;
    final target = saveAs
        ? await pickSaveAsTarget(widget.comparison)
        : _target ?? await askSaveTarget(context, widget.comparison);
    if (target == null || !mounted) return false;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await DiffSide.source(
        target,
      ).write(loaded.format.encode(doc.resultLines(labels: _labels)));
      // "Save as" with an output set is an extra copy: the output still
      // holds the old merge, so the work is not saved where it belongs.
      if (output == null || target == output) {
        _target = target;
        _savedRevision = doc.revision;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved the merge to ${target.label}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        _syncTab();
      }
    }
  }

  // ---- building ----

  MergeLayout _layout(MergeDocument doc) => MergeLayout(
        doc,
        rowExtent: mergeRowExtent,
        showBase: _showBase,
        editing: _editing,
        editorLines: _editorLines,
      );

  Map<ShortcutActivator, VoidCallback> _bindings() {
    if (_editing != null) {
      return bindActions({AppAction.save: () => _save()});
    }
    final bindings = bindActions({
      AppAction.save: () => _save(),
      AppAction.nextChange: () => _go(1),
      AppAction.previousChange: () => _go(-1),
      AppAction.copyToRight: () => _takeSelected(Resolution.left),
      AppAction.copyToLeft: () => _takeSelected(Resolution.right),
      AppAction.toggleEdit: () {
        final selected = _selected;
        if (selected != null) _startEdit(selected);
      },
      AppAction.undo: _undo,
      AppAction.redo: _redo,
      AppAction.refresh: _reload,
    });
    // Shift plus the take keys adds that side below what the chunk holds,
    // as shift-clicking the arrows does. Derived from the user's bindings
    // so a rebind of the take keys carries over.
    for (final (action, left) in [
      (AppAction.copyToRight, true),
      (AppAction.copyToLeft, false),
    ]) {
      final a = action.activator;
      if (a.shift) continue;
      final shifted = SingleActivator(
        a.trigger,
        control: a.control,
        alt: a.alt,
        meta: a.meta,
        shift: true,
      );
      bindings.putIfAbsent(
        shifted,
        () => () => _appendSelected(left: left),
      );
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _MergeProblem(
        message: error is MergeLoadException ? error.message : '$error',
        onRetry: _load,
        onBack: widget.onBack,
      );
    }
    final loaded = _loaded;
    if (loaded == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final doc = loaded.document;
    final colors = MergeColors.of(context);
    final layout = _layout(doc);
    final maxLines = math.max(
      doc.chunks.isEmpty
          ? 0
          : doc.chunks.last.leftStart + doc.chunks.last.left.length,
      math.max(
        doc.chunks.isEmpty
            ? 0
            : doc.chunks.last.rightStart + doc.chunks.last.right.length,
        doc.chunks.isEmpty
            ? 0
            : doc.chunks.last.baseStart + doc.chunks.last.base.length,
      ),
    );
    final numberWidth = lineNumberWidth(maxLines + 50);
    final actions = MergeRowActions(
      select: _select,
      tapMerged: _tapMerged,
      take: _take,
      append: _append,
      contextMenu: _showChunkMenu,
    );

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Column(
          children: [
            _toolbar(context, doc),
            _ChunkBar(
              doc: doc,
              selected: _selected,
              editing: _editing != null,
              onTake: _takeSelected,
              onEdit: () {
                final selected = _selected;
                if (selected != null) _startEdit(selected);
              },
            ),
            if (loaded.baseMissing || loaded.leftMissing || loaded.rightMissing)
              _MissingNotice(loaded: loaded),
            _ColumnHeaders(
              comparison: widget.comparison,
              showBase: _showBase,
              numberWidth: numberWidth,
              target: _target,
              loaded: loaded,
            ),
            const Divider(),
            Expanded(
              child: doc.chunks.isEmpty
                  ? Center(
                      child: Text(
                        'All three files are empty',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Scrollbar(
                            controller: _scroll,
                            child: ListView.builder(
                              controller: _scroll,
                              itemCount: layout.itemCount,
                              itemExtentBuilder: (index, _) =>
                                  layout.extentOf(index),
                              itemBuilder: (context, index) {
                                final chunk = layout.chunkAt(index);
                                if (chunk == _editing) {
                                  return MergeChunkEditor(
                                    layout: layout,
                                    chunk: chunk,
                                    colors: colors,
                                    numberWidth: numberWidth,
                                    controller: _editor,
                                    focusNode: _editorFocus,
                                    onApply: _commitEdit,
                                    onCancel: _cancelEdit,
                                  );
                                }
                                return MergeLineRow(
                                  layout: layout,
                                  chunk: chunk,
                                  row: index - layout.firstItemOf(chunk),
                                  selected: chunk == _selected,
                                  colors: colors,
                                  numberWidth: numberWidth,
                                  actions: actions,
                                );
                              },
                            ),
                          ),
                        ),
                        MergeChangeMap(
                          layout: layout,
                          colors: colors,
                          onJump: (chunk) {
                            final doc = _doc;
                            if (doc != null && doc.chunks[chunk].isChange) {
                              _select(chunk);
                            }
                            _reveal(chunk);
                          },
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, MergeDocument doc) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final targets = _navTargets(doc);
    final conflicts = doc.conflictIndexes.isNotEmpty;
    final position = _selected == null ? -1 : targets.indexOf(_selected!);
    final noun = conflicts ? 'conflict' : 'change';
    final saveTo = _target;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              tooltip: 'Back',
              onPressed: _back,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          const SizedBox(width: 4),
          Icon(Icons.merge_type, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    'Merge $_name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // The conflict count matters most: it keeps its size while
                // the title and the note beside it shrink.
                _StatusChip(doc: doc, palette: palette),
                Flexible(child: _AutoMergedNote(doc: doc)),
                if (_dirty)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '● unsaved',
                      style: TextStyle(fontSize: 11.5, color: palette.modified),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (targets.isNotEmpty) ...[
            Text(
              position < 0
                  ? '${targets.length} ${noun}s'
                  : '${noun[0].toUpperCase()}${noun.substring(1)} '
                      '${position + 1} / ${targets.length}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: 'Previous $noun (${AppAction.previousChange.keyLabel})',
              onPressed: _neighbour(-1) == null ? null : () => _go(-1),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Next $noun (${AppAction.nextChange.keyLabel})',
              onPressed: _neighbour(1) == null ? null : () => _go(1),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            tooltip: 'Undo (${AppAction.undo.keyLabel})',
            onPressed: doc.canUndo ? _undo : null,
            icon: const Icon(Icons.undo, size: 20),
          ),
          IconButton(
            tooltip: 'Redo (${AppAction.redo.keyLabel})',
            onPressed: doc.canRedo ? _redo : null,
            icon: const Icon(Icons.redo, size: 20),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Base'),
            tooltip: 'Show the common ancestor beside the others',
            avatar: Icon(Icons.call_split, size: 16, color: scheme.primary),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selected: _showBase,
            onSelected: (value) => setState(() => _showBase = value),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              if (conflicts) ...[
                PopupMenuItem(
                  value: () => _takeAll(Resolution.left),
                  child: const Text('Take left for every conflict'),
                ),
                PopupMenuItem(
                  value: () => _takeAll(Resolution.right),
                  child: const Text('Take right for every conflict'),
                ),
              ],
              PopupMenuItem(
                value: _resetAll,
                child: const Text('Start over from the automatic merge'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: () => _save(saveAs: true),
                child: const Text('Save to another file…'),
              ),
              PopupMenuItem(
                value: _reload,
                child: Text('Reload files (${AppAction.refresh.keyLabel})'),
              ),
            ],
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: saveTo == null
                ? 'Choose where to save (${AppAction.save.keyLabel})'
                : 'Save to ${saveTo.description} (${AppAction.save.keyLabel})',
            child: FilledButton.icon(
              onPressed: _saving ? null : () => _save(),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(saveTo == null ? 'Save…' : 'Save'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showChunkMenu(int chunk, Offset position) async {
    final doc = _doc;
    if (doc == null) return;
    _select(chunk);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final c = doc.chunks[chunk];
    final choice = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (c.isChange) ...[
          for (final r in _ChunkBar.takeChoices)
            PopupMenuItem(value: r.$1, child: Text(r.$2)),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: #edit, child: Text('Edit by hand…')),
        if (c.isChange || doc.state(chunk).resolution == Resolution.edited)
          PopupMenuItem(
            value: Resolution.automatic,
            child: Text(
              c.isConflict
                  ? 'Mark as unresolved again'
                  : 'Back to the automatic merge',
            ),
          ),
      ],
    );
    if (choice is Resolution) _take(chunk, choice);
    if (choice == #edit) _startEdit(chunk);
  }
}

/// "2 conflicts left" / "All conflicts resolved" / "No conflicts".
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.doc, required this.palette});

  final MergeDocument doc;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final unresolved = doc.unresolvedCount;
    final (icon, text, color) = unresolved > 0
        ? (
            Icons.warning_amber_rounded,
            unresolved == 1 ? '1 conflict left' : '$unresolved conflicts left',
            palette.removed,
          )
        : doc.conflictCount > 0
            ? (
                Icons.check_circle_outline,
                'All conflicts resolved',
                palette.added
              )
            : (Icons.check_circle_outline, 'No conflicts', palette.added);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// "3 changes merged automatically".
class _AutoMergedNote extends StatelessWidget {
  const _AutoMergedNote({required this.doc});

  final MergeDocument doc;

  @override
  Widget build(BuildContext context) {
    final auto = doc.changeIndexes.length - doc.conflictCount;
    if (auto == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Text(
        auto == 1
            ? '1 change merged automatically'
            : '$auto changes merged automatically',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Actions for the selected chunk, with their keys, so the keyboard
/// workflow is discoverable.
class _ChunkBar extends StatelessWidget {
  const _ChunkBar({
    required this.doc,
    required this.selected,
    required this.editing,
    required this.onTake,
    required this.onEdit,
  });

  final MergeDocument doc;
  final int? selected;
  final bool editing;
  final void Function(Resolution) onTake;
  final VoidCallback onEdit;

  static const takeChoices = [
    (Resolution.left, 'Take left'),
    (Resolution.right, 'Take right'),
    (Resolution.leftThenRight, 'Take both, left first'),
    (Resolution.rightThenLeft, 'Take both, right first'),
    (Resolution.base, 'Take base'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final index = selected;
    final style = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle:
          Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5),
    );

    Widget body;
    if (index == null) {
      body = Text(
        doc.changeIndexes.isEmpty
            ? 'The three files are identical.'
            : 'Select a change to resolve it, or jump to one with '
                '${AppAction.nextChange.keyLabel}.',
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      );
    } else {
      final chunk = doc.chunks[index];
      final state = doc.state(index);
      final ordinal = chunk.isConflict
          ? 'Conflict ${doc.conflictIndexes.indexOf(index) + 1} of '
              '${doc.conflictCount}'
          : chunk.isChange
              ? 'Change ${doc.changeIndexes.indexOf(index) + 1} of '
                  '${doc.changeIndexes.length}'
              : 'Unchanged lines';
      final color = !state.isResolved
          ? palette.removed
          : chunk.isConflict || state.resolution == Resolution.edited
              ? palette.added
              : palette.modified;
      body = Row(
        children: [
          Icon(
            !state.isResolved ? Icons.call_split : Icons.check_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: ordinal,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: ' · ${state.resolution.label}',
                    style: TextStyle(color: color),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 12),
          // On a narrow window the buttons scroll rather than overflow.
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (chunk.isChange) ...[
                      TextButton.icon(
                        style: style,
                        onPressed:
                            editing ? null : () => onTake(Resolution.left),
                        icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                        label: _KeyedLabel('Left', AppAction.copyToRight),
                      ),
                      TextButton.icon(
                        style: style,
                        onPressed:
                            editing ? null : () => onTake(Resolution.right),
                        icon: const Icon(Icons.arrow_back_rounded, size: 16),
                        label: _KeyedLabel('Right', AppAction.copyToLeft),
                      ),
                      PopupMenuButton<Resolution>(
                        tooltip: 'Take both sides',
                        enabled: !editing,
                        onSelected: onTake,
                        itemBuilder: (context) => [
                          for (final r in takeChoices.sublist(2, 4))
                            PopupMenuItem(value: r.$1, child: Text(r.$2)),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.vertical_split_outlined,
                                size: 16,
                                color:
                                    editing ? scheme.outline : scheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Both',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color:
                                      editing ? scheme.outline : scheme.primary,
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 18,
                                color:
                                    editing ? scheme.outline : scheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                      TextButton.icon(
                        style: style,
                        onPressed:
                            editing ? null : () => onTake(Resolution.base),
                        icon: const Icon(Icons.call_split, size: 16),
                        label: const Text('Base'),
                      ),
                    ],
                    TextButton.icon(
                      style: style,
                      onPressed: editing ? null : onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: _KeyedLabel('Edit', AppAction.toggleEdit),
                    ),
                    if (chunk.isChange || state.resolution == Resolution.edited)
                      TextButton.icon(
                        style: style,
                        onPressed: editing ||
                                state.resolution == Resolution.automatic ||
                                !state.isResolved
                            ? null
                            : () => onTake(Resolution.automatic),
                        icon: const Icon(Icons.restart_alt, size: 16),
                        label: const Text('Reset'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      height: 40,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerLeft,
      child: body,
    );
  }
}

/// A button label with its keyboard shortcut in a small key cap.
class _KeyedLabel extends StatelessWidget {
  const _KeyedLabel(this.text, this.action);

  final String text;
  final AppAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            action.keyLabel,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _MissingNotice extends StatelessWidget {
  const _MissingNotice({required this.loaded});

  final LoadedMerge loaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final missing = [
      if (loaded.baseMissing) 'base',
      if (loaded.leftMissing) 'left',
      if (loaded.rightMissing) 'right',
    ];
    final text = loaded.baseMissing && missing.length == 1
        ? 'There is no base file, so everything either side has is treated '
            'as added: where both added different text, that is a conflict.'
        : 'The ${missing.join(' and ')} file does not exist and is treated '
            'as empty.';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnHeaders extends StatelessWidget {
  const _ColumnHeaders({
    required this.comparison,
    required this.showBase,
    required this.numberWidth,
    required this.target,
    required this.loaded,
  });

  final ThreeWayComparison comparison;
  final bool showBase;
  final double numberWidth;
  final SourceSpec? target;
  final LoadedMerge loaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget header(
      String role,
      String name,
      String tooltip,
      IconData icon, {
      bool emphasis = false,
    }) {
      return Expanded(
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: EdgeInsets.only(left: numberWidth - 18),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: emphasis ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  '$role  ',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: emphasis ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    String described(SourceSpec spec, bool missing) =>
        missing ? '${spec.description} (does not exist)' : spec.description;

    return SizedBox(
      height: 26,
      child: Row(
        children: [
          if (showBase) ...[
            header(
              'BASE',
              comparison.base.label,
              described(comparison.base, loaded.baseMissing),
              Icons.call_split,
            ),
            const SizedBox(width: 1),
          ],
          header(
            'LEFT',
            comparison.left.label,
            described(comparison.left, loaded.leftMissing),
            Icons.west,
          ),
          const SizedBox(width: mergeGutterWidth),
          header(
            'MERGED',
            target == null ? 'not saved yet' : '→ ${target!.label}',
            target == null
                ? 'You will be asked where to save'
                : 'Saves to ${target!.description}',
            Icons.merge_type,
            emphasis: true,
          ),
          const SizedBox(width: mergeGutterWidth),
          header(
            'RIGHT',
            comparison.right.label,
            described(comparison.right, loaded.rightMissing),
            Icons.east,
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

class _MergeProblem extends StatelessWidget {
  const _MergeProblem({
    required this.message,
    required this.onRetry,
    this.onBack,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.merge_type, size: 42, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            'Cannot merge these files',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onBack != null) ...[
                TextButton(onPressed: onBack, child: const Text('Back')),
                const SizedBox(width: 8),
              ],
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
