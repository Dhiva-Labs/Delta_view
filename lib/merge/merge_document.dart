/// The state of a three-way merge in progress: how each chunk is resolved,
/// with undo and redo, and the merged text that results.
///
/// Pure Dart. The merge view owns one and rebuilds after each call.
library;

import 'diff3.dart';

export 'diff3.dart';

/// Where a chunk's merged lines came from.
enum Resolution {
  /// The diff3 answer for a chunk that merged cleanly.
  automatic,

  /// A conflict nobody has resolved yet. It is saved as conflict markers.
  unresolved,
  left,
  right,
  leftThenRight,
  rightThenLeft,
  base,

  /// Typed by hand.
  edited;

  String get label => switch (this) {
        automatic => 'merged automatically',
        unresolved => 'unresolved',
        left => 'took left',
        right => 'took right',
        leftThenRight => 'took left, then right',
        rightThenLeft => 'took right, then left',
        base => 'took base',
        edited => 'edited by hand',
      };
}

class ChunkState {
  const ChunkState(this.resolution, this.lines);

  final Resolution resolution;

  /// The merged lines for the chunk. For an unresolved conflict these are
  /// the base lines, shown as a placeholder; saving writes markers instead.
  final List<String> lines;

  bool get isResolved => resolution != Resolution.unresolved;
}

/// Names written into conflict markers (`<<<<<<< left` and so on).
class MergeLabels {
  const MergeLabels({
    this.left = 'left',
    this.base = 'base',
    this.right = 'right',
  });

  final String left;
  final String base;
  final String right;
}

class _Change {
  const _Change(this.index, this.before, this.after);

  final int index;
  final ChunkState before;
  final ChunkState after;
}

class _Step {
  const _Step(this.changes, this.revision);

  final List<_Change> changes;
  final int revision;
}

class MergeDocument {
  MergeDocument(this.chunks)
      : _states = [for (final c in chunks) _initial(c)],
        conflictIndexes = List.unmodifiable([
          for (var i = 0; i < chunks.length; i++)
            if (chunks[i].isConflict) i,
        ]),
        changeIndexes = List.unmodifiable([
          for (var i = 0; i < chunks.length; i++)
            if (chunks[i].isChange) i,
        ]);

  /// Merges three versions with [diff3Merge].
  factory MergeDocument.merge(
          List<String> base, List<String> left, List<String> right) =>
      MergeDocument(diff3Merge(base, left, right));

  final List<MergeChunk> chunks;
  final List<ChunkState> _states;

  /// Indexes of the chunks that conflict, resolved or not.
  final List<int> conflictIndexes;

  /// Indexes of every chunk that is not [MergeChunkKind.unchanged].
  final List<int> changeIndexes;

  final List<_Step> _undo = [];
  final List<_Step> _redo = [];
  int _revisions = 0;

  static ChunkState _initial(MergeChunk chunk) => chunk.isConflict
      ? ChunkState(Resolution.unresolved, chunk.base)
      : ChunkState(Resolution.automatic, chunk.automatic);

  ChunkState state(int index) => _states[index];

  int get conflictCount => conflictIndexes.length;

  int get unresolvedCount =>
      conflictIndexes.where((i) => !_states[i].isResolved).length;

  /// Identifies the current content: it changes with every edit and comes
  /// back when undo or redo returns to an earlier state. A view remembers
  /// the revision it saved to tell whether there are unsaved changes.
  int get revision => _undo.isEmpty ? 0 : _undo.last.revision;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The lines [resolution] gives [chunk]. [Resolution.edited] has no
  /// lines of its own; it returns the current ones.
  List<String> linesFor(int index, Resolution resolution) {
    final chunk = chunks[index];
    return switch (resolution) {
      Resolution.automatic =>
        chunk.isConflict ? chunk.base : chunk.automatic,
      Resolution.unresolved => chunk.base,
      Resolution.left => chunk.left,
      Resolution.right => chunk.right,
      Resolution.leftThenRight => [...chunk.left, ...chunk.right],
      Resolution.rightThenLeft => [...chunk.right, ...chunk.left],
      Resolution.base => chunk.base,
      Resolution.edited => _states[index].lines,
    };
  }

  /// Resolves chunk [index] with [resolution]. [Resolution.automatic]
  /// resets it: a conflict goes back to unresolved.
  void take(int index, Resolution resolution) {
    assert(resolution != Resolution.edited, 'use edit() for typed lines');
    _apply([(index, _stateFor(index, resolution))]);
  }

  /// Resolves every conflict with [resolution] in one undoable step (for
  /// "take left / right everywhere"). Leaves clean chunks alone.
  void takeAllConflicts(Resolution resolution) {
    _apply([
      for (final i in conflictIndexes) (i, _stateFor(i, resolution)),
    ]);
  }

  /// Puts every chunk back to the automatic merge, in one undoable step.
  void resetAll() {
    _apply([
      for (var i = 0; i < chunks.length; i++) (i, _initial(chunks[i])),
    ]);
  }

  /// Adds one side's lines after what the chunk holds now, Meld-style:
  /// take left, then append right, gives "left then right". An unresolved
  /// conflict holds nothing yet, so appending to it takes that side.
  void append(int index, {required bool left}) {
    final current = _states[index];
    final chunk = chunks[index];
    final lines = [
      if (current.isResolved) ...current.lines,
      ...(left ? chunk.left : chunk.right),
    ];
    _apply([(index, _classify(index, lines))]);
  }

  /// Replaces the chunk's merged lines with [lines] typed by the user.
  /// When they happen to equal one of the sides, the chunk says so.
  void edit(int index, List<String> lines) {
    _apply([(index, _classify(index, lines))]);
  }

  ChunkState _stateFor(int index, Resolution resolution) =>
      resolution == Resolution.automatic || resolution == Resolution.unresolved
          ? _initial(chunks[index])
          : ChunkState(resolution, linesFor(index, resolution));

  ChunkState _classify(int index, List<String> lines) {
    final chunk = chunks[index];
    if (!chunk.isConflict && _same(lines, chunk.automatic)) {
      return ChunkState(Resolution.automatic, chunk.automatic);
    }
    for (final r in const [
      Resolution.left,
      Resolution.right,
      Resolution.leftThenRight,
      Resolution.rightThenLeft,
      Resolution.base,
    ]) {
      final candidate = linesFor(index, r);
      if (_same(lines, candidate)) return ChunkState(r, candidate);
    }
    return ChunkState(Resolution.edited, List.unmodifiable(lines));
  }

  void _apply(List<(int, ChunkState)> updates) {
    final changes = <_Change>[];
    for (final (index, after) in updates) {
      final before = _states[index];
      if (before.resolution == after.resolution &&
          _same(before.lines, after.lines)) {
        continue;
      }
      changes.add(_Change(index, before, after));
      _states[index] = after;
    }
    if (changes.isEmpty) return;
    _undo.add(_Step(changes, ++_revisions));
    _redo.clear();
  }

  /// Reverts the last step. Returns the chunk it touched first, so the
  /// view can bring it into sight, or null when there was nothing to undo.
  int? undo() {
    if (_undo.isEmpty) return null;
    final step = _undo.removeLast();
    for (final c in step.changes.reversed) {
      _states[c.index] = c.before;
    }
    _redo.add(step);
    return step.changes.first.index;
  }

  int? redo() {
    if (_redo.isEmpty) return null;
    final step = _redo.removeLast();
    for (final c in step.changes) {
      _states[c.index] = c.after;
    }
    _undo.add(step);
    return step.changes.first.index;
  }

  /// The merged file's lines. Unresolved conflicts are written as diff3
  /// style conflict markers, so saving early never silently drops either
  /// side's change and tools like git still see the conflict.
  List<String> resultLines({MergeLabels labels = const MergeLabels()}) {
    final out = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final state = _states[i];
      if (state.isResolved) {
        out.addAll(state.lines);
      } else {
        out.addAll(conflictMarkers(i, labels: labels));
      }
    }
    return out;
  }

  /// Chunk [index] as conflict markers, also the starting text when the
  /// user edits an unresolved conflict by hand.
  List<String> conflictMarkers(int index,
      {MergeLabels labels = const MergeLabels()}) {
    final chunk = chunks[index];
    return [
      '<<<<<<< ${labels.left}',
      ...chunk.left,
      '||||||| ${labels.base}',
      ...chunk.base,
      '=======',
      ...chunk.right,
      '>>>>>>> ${labels.right}',
    ];
  }

  static bool _same(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
