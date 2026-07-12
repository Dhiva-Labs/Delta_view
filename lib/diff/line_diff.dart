/// Line-based diff built on Myers' O(ND) algorithm, plus a small
/// intra-line refinement so changed line pairs can highlight the exact
/// characters that differ.
library;

enum DiffOp { equal, delete, insert }

class DiffChunk {
  const DiffChunk(this.op, this.lines);

  final DiffOp op;
  final List<String> lines;
}

/// One row of a side-by-side diff. Either side may be absent (null line
/// number) for pure insertions/deletions.
class DiffRow {
  const DiffRow({
    this.leftNumber,
    this.rightNumber,
    this.leftText,
    this.rightText,
    required this.kind,
    this.leftSpans,
    this.rightSpans,
  });

  final int? leftNumber;
  final int? rightNumber;
  final String? leftText;
  final String? rightText;
  final DiffRowKind kind;

  /// Intra-line highlight ranges (start, end) into the text, marking the
  /// parts that changed. Only set for [DiffRowKind.modified].
  final List<(int, int)>? leftSpans;
  final List<(int, int)>? rightSpans;
}

enum DiffRowKind { same, added, removed, modified }

class DiffResult {
  const DiffResult(this.rows, this.changeBlocks);

  final List<DiffRow> rows;

  /// Row indices where each contiguous change block starts — used for
  /// previous/next-change navigation and the change minimap.
  final List<int> changeBlocks;

  int get addedCount =>
      rows.where((r) => r.kind == DiffRowKind.added).length;
  int get removedCount =>
      rows.where((r) => r.kind == DiffRowKind.removed).length;
  int get modifiedCount =>
      rows.where((r) => r.kind == DiffRowKind.modified).length;
}

/// Myers diff over arbitrary lists of comparable items (here: line hashes).
List<DiffChunk> diffLines(List<String> a, List<String> b) {
  // Strip common prefix/suffix first — cheap and makes Myers much faster
  // on typical "small edit in a large file" inputs.
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }

  final chunks = <DiffChunk>[];
  if (start > 0) chunks.add(DiffChunk(DiffOp.equal, a.sublist(0, start)));
  chunks.addAll(_myers(a.sublist(start, endA), b.sublist(start, endB)));
  if (endA < a.length) chunks.add(DiffChunk(DiffOp.equal, a.sublist(endA)));
  return _coalesce(chunks);
}

/// Hard cap on the edit distance the exact Myers search will explore.
/// Bounds both time (O(D·(N+M))) and memory (O(D²)); beyond it the two
/// ranges are reported as one whole-block replacement, which keeps huge,
/// wildly different files (lock files, minified bundles) instant instead
/// of hanging for minutes.
const _maxEditDistance = 1200;

List<DiffChunk> _myers(List<String> a, List<String> b) {
  if (a.isEmpty && b.isEmpty) return const [];
  if (a.isEmpty) return [DiffChunk(DiffOp.insert, List.of(b))];
  if (b.isEmpty) return [DiffChunk(DiffOp.delete, List.of(a))];

  // Intern lines so the hot loop compares small ints, not strings.
  final ids = <String, int>{};
  final ai = List<int>.generate(
      a.length, (i) => ids.putIfAbsent(a[i], () => ids.length));
  final bi = List<int>.generate(
      b.length, (i) => ids.putIfAbsent(b[i], () => ids.length));

  final ops = _myersOps(ai, bi, _maxEditDistance);
  if (ops == null) {
    // Too different for an exact diff within the cap — coarse fallback.
    return [
      DiffChunk(DiffOp.delete, List.of(a)),
      DiffChunk(DiffOp.insert, List.of(b)),
    ];
  }

  // ops are reversed; walk backwards building chunks.
  final chunks = <DiffChunk>[];
  var ax = 0, bx = 0;
  for (var i = ops.length - 1; i >= 0; i--) {
    final op = ops[i];
    switch (op) {
      case DiffOp.equal:
        _append(chunks, op, a[ax]);
        ax++;
        bx++;
      case DiffOp.delete:
        _append(chunks, op, a[ax]);
        ax++;
      case DiffOp.insert:
        _append(chunks, op, b[bx]);
        bx++;
    }
  }
  return chunks;
}

/// Bounded Myers search over interned line ids. Returns the edit script in
/// reverse order, or null when the edit distance exceeds [maxD].
List<DiffOp>? _myersOps(List<int> a, List<int> b, int maxD) {
  final n = a.length;
  final m = b.length;
  final off = maxD;
  final v = List<int>.filled(2 * maxD + 1, 0);
  final trace = <List<int>>[];
  var found = false;

  for (var d = 0; d <= maxD && !found; d++) {
    // Only the k-range [-d, d] is live; storing just that slice keeps the
    // trace at O(D²) instead of O(D·(N+M)).
    trace.add(List<int>.from(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) {
        x = v[off + k + 1];
      } else {
        x = v[off + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) {
        found = true;
        break;
      }
    }
  }
  if (!found) return null;

  final ops = <DiffOp>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    final vPrev = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && vPrev[off + k - 1] < vPrev[off + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = vPrev[off + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(DiffOp.equal);
      x--;
      y--;
    }
    if (x > prevX) {
      ops.add(DiffOp.delete);
      x--;
    } else if (y > prevY) {
      ops.add(DiffOp.insert);
      y--;
    }
  }
  while (x > 0 && y > 0) {
    ops.add(DiffOp.equal);
    x--;
    y--;
  }
  while (x > 0) {
    ops.add(DiffOp.delete);
    x--;
  }
  while (y > 0) {
    ops.add(DiffOp.insert);
    y--;
  }
  return ops;
}

void _append(List<DiffChunk> chunks, DiffOp op, String line) {
  if (chunks.isNotEmpty && chunks.last.op == op) {
    chunks.last.lines.add(line);
  } else {
    chunks.add(DiffChunk(op, [line]));
  }
}

List<DiffChunk> _coalesce(List<DiffChunk> chunks) {
  final out = <DiffChunk>[];
  for (final c in chunks) {
    if (c.lines.isEmpty) continue;
    if (out.isNotEmpty && out.last.op == c.op) {
      out.last.lines.addAll(c.lines);
    } else {
      out.add(DiffChunk(c.op, List.of(c.lines)));
    }
  }
  return out;
}

/// Builds side-by-side rows from two texts, pairing deletions with
/// insertions in the same block as "modified" rows.
DiffResult buildSideBySide(String leftText, String rightText) {
  final a = _splitLines(leftText);
  final b = _splitLines(rightText);
  final chunks = diffLines(a, b);

  final rows = <DiffRow>[];
  final blocks = <int>[];
  var leftNo = 1, rightNo = 1;
  var inBlock = false;

  void markBlock() {
    if (!inBlock) {
      blocks.add(rows.length);
      inBlock = true;
    }
  }

  for (var i = 0; i < chunks.length; i++) {
    final c = chunks[i];
    switch (c.op) {
      case DiffOp.equal:
        inBlock = false;
        for (final line in c.lines) {
          rows.add(DiffRow(
            leftNumber: leftNo++,
            rightNumber: rightNo++,
            leftText: line,
            rightText: line,
            kind: DiffRowKind.same,
          ));
        }
      case DiffOp.delete:
        markBlock();
        // Pair with a following insert chunk if present → modified rows.
        final next = i + 1 < chunks.length ? chunks[i + 1] : null;
        if (next != null && next.op == DiffOp.insert) {
          final dels = c.lines;
          final ins = next.lines;
          final paired = dels.length < ins.length ? dels.length : ins.length;
          for (var j = 0; j < paired; j++) {
            final spans = _intraLine(dels[j], ins[j]);
            rows.add(DiffRow(
              leftNumber: leftNo++,
              rightNumber: rightNo++,
              leftText: dels[j],
              rightText: ins[j],
              kind: DiffRowKind.modified,
              leftSpans: spans.$1,
              rightSpans: spans.$2,
            ));
          }
          for (var j = paired; j < dels.length; j++) {
            rows.add(DiffRow(
              leftNumber: leftNo++,
              leftText: dels[j],
              kind: DiffRowKind.removed,
            ));
          }
          for (var j = paired; j < ins.length; j++) {
            rows.add(DiffRow(
              rightNumber: rightNo++,
              rightText: ins[j],
              kind: DiffRowKind.added,
            ));
          }
          i++; // consume the insert chunk
        } else {
          for (final line in c.lines) {
            rows.add(DiffRow(
              leftNumber: leftNo++,
              leftText: line,
              kind: DiffRowKind.removed,
            ));
          }
        }
      case DiffOp.insert:
        markBlock();
        for (final line in c.lines) {
          rows.add(DiffRow(
            rightNumber: rightNo++,
            rightText: line,
            kind: DiffRowKind.added,
          ));
        }
    }
  }
  return DiffResult(rows, blocks);
}

/// Splits text into lines, dropping the phantom empty element a trailing
/// newline would produce.
List<String> splitLines(String text) => _splitLines(text);

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  // A trailing newline produces a phantom empty last element.
  if (lines.isNotEmpty && lines.last.isEmpty && text.endsWith('\n')) {
    lines.removeLast();
  }
  return lines;
}

/// Character-level common prefix/suffix trim: highlights the middle part
/// of each line that actually changed.
(List<(int, int)>, List<(int, int)>) _intraLine(String a, String b) {
  var start = 0;
  final minLen = a.length < b.length ? a.length : b.length;
  while (start < minLen && a.codeUnitAt(start) == b.codeUnitAt(start)) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start &&
      endB > start &&
      a.codeUnitAt(endA - 1) == b.codeUnitAt(endB - 1)) {
    endA--;
    endB--;
  }
  final left = start < endA ? [(start, endA)] : <(int, int)>[];
  final right = start < endB ? [(start, endB)] : <(int, int)>[];
  return (left, right);
}
