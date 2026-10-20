/// Three-way line merge (diff3): what the left and right versions each
/// changed relative to their common base, grouped into chunks that either
/// merge cleanly or conflict.
///
/// Pure Dart, no Flutter: it runs in isolates and is unit-tested directly.
library;

import 'dart:math' as math;

import '../diff/line_diff.dart';

enum MergeChunkKind {
  /// Neither side touched these base lines.
  unchanged,

  /// Only the left side changed this region; the merge takes left.
  leftOnly,

  /// Only the right side changed this region; the merge takes right.
  rightOnly,

  /// Both sides made the same change; the merge takes it once.
  bothSame,

  /// Both sides changed overlapping (or touching) lines differently.
  conflict,
}

/// One region of the merge. Chunks tile all three inputs in order:
/// concatenating every chunk's [base], [left] or [right] gives back that
/// input exactly. Chunk boundaries never move once computed, so a view can
/// key its per-chunk state (resolutions, selection) by index.
class MergeChunk {
  const MergeChunk({
    required this.kind,
    required this.base,
    required this.left,
    required this.right,
    required this.baseStart,
    required this.leftStart,
    required this.rightStart,
  });

  final MergeChunkKind kind;
  final List<String> base;
  final List<String> left;
  final List<String> right;

  /// Zero-based index of this chunk's first line in each input.
  final int baseStart;
  final int leftStart;
  final int rightStart;

  bool get isChange => kind != MergeChunkKind.unchanged;
  bool get isConflict => kind == MergeChunkKind.conflict;

  /// What the merge holds for this chunk before anyone resolves anything.
  /// A conflict has no automatic answer; it keeps the base lines until the
  /// user picks one (they are what [MergeDocument] shows as a placeholder).
  List<String> get automatic => switch (kind) {
        MergeChunkKind.unchanged => base,
        MergeChunkKind.leftOnly => left,
        MergeChunkKind.rightOnly => right,
        MergeChunkKind.bothSame => left,
        MergeChunkKind.conflict => base,
      };

  @override
  String toString() => 'MergeChunk(${kind.name}, base $baseStart+'
      '${base.length}, left $leftStart+${left.length}, '
      'right $rightStart+${right.length})';
}

/// A contiguous region of base lines `[baseStart, baseEnd)` that one side
/// replaced with its lines `[sideStart, sideEnd)`. Insertions have an empty
/// base range, deletions an empty side range.
class _Hunk {
  const _Hunk(this.baseStart, this.baseEnd, this.sideStart, this.sideEnd,
      this.isLeft);

  final int baseStart, baseEnd, sideStart, sideEnd;
  final bool isLeft;
}

List<_Hunk> _hunks(List<String> base, List<String> side, {required bool left}) {
  final out = <_Hunk>[];
  var b = 0, s = 0;
  (int, int)? open;
  for (final chunk in diffLines(base, side)) {
    switch (chunk.op) {
      case DiffOp.equal:
        if (open != null) {
          out.add(_Hunk(open.$1, b, open.$2, s, left));
          open = null;
        }
        b += chunk.lines.length;
        s += chunk.lines.length;
      case DiffOp.delete:
        open ??= (b, s);
        b += chunk.lines.length;
      case DiffOp.insert:
        open ??= (b, s);
        s += chunk.lines.length;
    }
  }
  if (open != null) out.add(_Hunk(open.$1, b, open.$2, s, left));
  return out;
}

/// Merges [left] and [right], two edits of [base], line by line.
///
/// Changes from each side are found with [diffLines] against the base.
/// Changes whose base ranges overlap, or merely touch, are grouped into
/// one chunk and conflict unless both sides produced the same lines. That
/// matches `git merge-file`: two edits on neighbouring lines are a conflict,
/// because nothing guarantees they still make sense together.
List<MergeChunk> diff3Merge(
    List<String> base, List<String> left, List<String> right) {
  final hunks = [
    ..._hunks(base, left, left: true),
    ..._hunks(base, right, left: false),
  ]..sort((a, b) => a.baseStart != b.baseStart
      ? a.baseStart.compareTo(b.baseStart)
      : a.baseEnd.compareTo(b.baseEnd));

  final chunks = <MergeChunk>[];
  // Outside of hunks, line i of base is line i + delta of that side.
  var leftDelta = 0, rightDelta = 0;
  var cursor = 0;

  void unchanged(int end) {
    if (end <= cursor) return;
    chunks.add(MergeChunk(
      kind: MergeChunkKind.unchanged,
      base: base.sublist(cursor, end),
      left: base.sublist(cursor, end),
      right: base.sublist(cursor, end),
      baseStart: cursor,
      leftStart: cursor + leftDelta,
      rightStart: cursor + rightDelta,
    ));
  }

  var i = 0;
  while (i < hunks.length) {
    final start = hunks[i].baseStart;
    var end = hunks[i].baseEnd;
    final group = <_Hunk>[hunks[i++]];
    while (i < hunks.length && hunks[i].baseStart <= end) {
      end = math.max(end, hunks[i].baseEnd);
      group.add(hunks[i++]);
    }
    unchanged(start);

    final lefts = [for (final h in group) if (h.isLeft) h];
    final rights = [for (final h in group) if (!h.isLeft) h];

    // Each side's lines for the whole base region: its hunks plus the
    // unchanged base lines around them, mapped through the side's offset.
    (int, int) sideRange(List<_Hunk> sideHunks, int delta) {
      if (sideHunks.isEmpty) return (start + delta, end + delta);
      final first = sideHunks.first, last = sideHunks.last;
      return (
        first.sideStart - (first.baseStart - start),
        last.sideEnd + (end - last.baseEnd),
      );
    }

    final (ls, le) = sideRange(lefts, leftDelta);
    final (rs, re) = sideRange(rights, rightDelta);
    final baseLines = base.sublist(start, end);
    final leftLines = left.sublist(ls, le);
    final rightLines = right.sublist(rs, re);

    // A side whose hunks cancel out over the region (say, a line moved
    // within it) changed nothing here after all.
    final leftSame = lefts.isEmpty || _sameLines(leftLines, baseLines);
    final rightSame = rights.isEmpty || _sameLines(rightLines, baseLines);
    MergeChunkKind kind;
    if (leftSame && rightSame) {
      kind = MergeChunkKind.unchanged;
    } else if (rightSame) {
      kind = MergeChunkKind.leftOnly;
    } else if (leftSame) {
      kind = MergeChunkKind.rightOnly;
    } else if (_sameLines(leftLines, rightLines)) {
      kind = MergeChunkKind.bothSame;
    } else {
      kind = MergeChunkKind.conflict;
    }

    chunks.add(MergeChunk(
      kind: kind,
      base: baseLines,
      left: leftLines,
      right: rightLines,
      baseStart: start,
      leftStart: ls,
      rightStart: rs,
    ));

    if (lefts.isNotEmpty) leftDelta = lefts.last.sideEnd - lefts.last.baseEnd;
    if (rights.isNotEmpty) {
      rightDelta = rights.last.sideEnd - rights.last.baseEnd;
    }
    cursor = end;
  }
  unchanged(base.length);
  return chunks;
}

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
