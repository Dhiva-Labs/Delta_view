/// Line-based diff built on Myers' O(ND) algorithm, plus a word-level
/// intra-line refinement so changed line pairs can highlight the exact
/// parts that differ. Both honour [CompareOptions].
library;

import 'dart:math' as math;

import 'compare_options.dart';

export 'compare_options.dart';

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

  int get addedCount => rows.where((r) => r.kind == DiffRowKind.added).length;
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
///
/// Lines are matched by their [CompareOptions.normalize] key, so lines that
/// differ only in what [options] ignores count as the same, but every row
/// keeps the original text for display. Lines may keep a trailing `\r`
/// (CRLF files); views strip it when painting. The default, exact options
/// match lines character for character.
DiffResult buildSideBySide(String leftText, String rightText,
    {CompareOptions options = CompareOptions.exact}) {
  final a = _splitLines(leftText);
  final b = _splitLines(rightText);

  // The lines that take part in the comparison, as keys, plus where each
  // one sits in its side. Blank lines drop out under ignoreBlankLines and
  // are put back between their neighbours as unchanged rows.
  final exact = options.isExact;
  final aKeys = <String>[], aAt = <int>[];
  final bKeys = <String>[], bAt = <int>[];
  for (var i = 0; i < a.length; i++) {
    if (options.isIgnoredBlank(a[i])) continue;
    aKeys.add(exact ? a[i] : options.normalize(a[i]));
    aAt.add(i);
  }
  for (var i = 0; i < b.length; i++) {
    if (options.isIgnoredBlank(b[i])) continue;
    bKeys.add(exact ? b[i] : options.normalize(b[i]));
    bAt.add(i);
  }
  final chunks = diffLines(aKeys, bKeys);

  final rows = <DiffRow>[];
  var nextA = 0, nextB = 0; // next original line not yet emitted, per side
  var ka = 0, kb = 0; // position in the key lists

  // Emits the ignored lines that come before original lines [untilA] and
  // [untilB], side by side where both sides have some.
  void flushIgnored(int untilA, int untilB) {
    while (nextA < untilA || nextB < untilB) {
      final hasA = nextA < untilA, hasB = nextB < untilB;
      rows.add(DiffRow(
        leftNumber: hasA ? nextA + 1 : null,
        rightNumber: hasB ? nextB + 1 : null,
        leftText: hasA ? a[nextA] : null,
        rightText: hasB ? b[nextB] : null,
        kind: DiffRowKind.same,
      ));
      if (hasA) nextA++;
      if (hasB) nextB++;
    }
  }

  void emitLeft(DiffRowKind kind) {
    final i = aAt[ka++];
    flushIgnored(i, nextB);
    rows.add(DiffRow(leftNumber: i + 1, leftText: a[i], kind: kind));
    nextA = i + 1;
  }

  void emitRight(DiffRowKind kind) {
    final j = bAt[kb++];
    flushIgnored(nextA, j);
    rows.add(DiffRow(rightNumber: j + 1, rightText: b[j], kind: kind));
    nextB = j + 1;
  }

  void emitPair(DiffRowKind kind) {
    final i = aAt[ka++], j = bAt[kb++];
    flushIgnored(i, j);
    final (leftSpans, rightSpans) = kind == DiffRowKind.modified
        ? intraLineSpans(a[i], b[j], options)
        : (null, null);
    rows.add(DiffRow(
      leftNumber: i + 1,
      rightNumber: j + 1,
      leftText: a[i],
      rightText: b[j],
      kind: kind,
      leftSpans: leftSpans,
      rightSpans: rightSpans,
    ));
    nextA = i + 1;
    nextB = j + 1;
  }

  for (var c = 0; c < chunks.length; c++) {
    final chunk = chunks[c];
    switch (chunk.op) {
      case DiffOp.equal:
        for (var n = 0; n < chunk.lines.length; n++) {
          emitPair(DiffRowKind.same);
        }
      case DiffOp.delete:
        // Pair with a following insert chunk if present → modified rows.
        final next = c + 1 < chunks.length ? chunks[c + 1] : null;
        if (next != null && next.op == DiffOp.insert) {
          final dels = chunk.lines.length, ins = next.lines.length;
          final paired = math.min(dels, ins);
          for (var n = 0; n < paired; n++) {
            emitPair(DiffRowKind.modified);
          }
          for (var n = paired; n < dels; n++) {
            emitLeft(DiffRowKind.removed);
          }
          for (var n = paired; n < ins; n++) {
            emitRight(DiffRowKind.added);
          }
          c++; // consume the insert chunk
        } else {
          for (var n = 0; n < chunk.lines.length; n++) {
            emitLeft(DiffRowKind.removed);
          }
        }
      case DiffOp.insert:
        for (var n = 0; n < chunk.lines.length; n++) {
          emitRight(DiffRowKind.added);
        }
    }
  }
  flushIgnored(a.length, b.length);

  final blocks = <int>[];
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind != DiffRowKind.same &&
        (i == 0 || rows[i - 1].kind == DiffRowKind.same)) {
      blocks.add(i);
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

/// Lines longer than this (combined) skip the word diff and only trim the
/// common prefix and suffix, which is linear.
const _maxWordDiffLength = 4000;

/// The parts of two paired lines that differ, as (start, end) ranges into
/// each line, for intra-line emphasis.
///
/// Works on words, whitespace runs and punctuation so a renamed identifier
/// lights up as a whole, then narrows a single replaced word down to the
/// characters that changed. Whatever [options] ignores (case, whitespace)
/// is never highlighted. A trailing `\r` is left out: views show line
/// ending differences separately.
(List<(int, int)>, List<(int, int)>) intraLineSpans(
    String a, String b, CompareOptions options) {
  if (a.endsWith('\r')) a = a.substring(0, a.length - 1);
  if (b.endsWith('\r')) b = b.substring(0, b.length - 1);
  if (a.length + b.length > _maxWordDiffLength) {
    return _trimSpans(a, 0, a.length, b, 0, b.length, options.ignoreCase);
  }

  final ta = _tokens(a, options), tb = _tokens(b, options);
  final chunks =
      diffLines([for (final t in ta) t.key], [for (final t in tb) t.key]);

  final left = <(int, int)>[], right = <(int, int)>[];
  var ia = 0, ib = 0;
  for (var c = 0; c < chunks.length; c++) {
    final chunk = chunks[c];
    final n = chunk.lines.length;
    switch (chunk.op) {
      case DiffOp.equal:
        ia += n;
        ib += n;
      case DiffOp.delete:
        final next = c + 1 < chunks.length ? chunks[c + 1] : null;
        if (n == 1 &&
            next != null &&
            next.op == DiffOp.insert &&
            next.lines.length == 1) {
          // One word swapped for another: show just the characters that
          // changed (`count` → `counter` highlights `er`).
          final x = ta[ia], y = tb[ib];
          final (l, r) = _trimSpans(
              a, x.start, x.end, b, y.start, y.end, options.ignoreCase);
          left.addAll(l);
          right.addAll(r);
          ia++;
          ib++;
          c++;
        } else {
          for (var k = 0; k < n; k++) {
            left.add((ta[ia].start, ta[ia].end));
            ia++;
          }
        }
      case DiffOp.insert:
        for (var k = 0; k < n; k++) {
          right.add((tb[ib].start, tb[ib].end));
          ib++;
        }
    }
  }
  // Join neighbouring ranges separated only by whitespace that counts, so
  // a changed phrase reads as one highlight instead of a row of words.
  final joinAcrossSpaces = options.whitespace == WhitespaceMode.exact ||
      options.whitespace == WhitespaceMode.trailing;
  return (
    _mergeSpans(a, left, joinAcrossSpaces),
    _mergeSpans(b, right, joinAcrossSpaces),
  );
}

class _Token {
  const _Token(this.key, this.start, this.end);

  final String key;
  final int start;
  final int end;
}

bool _isSpace(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0D ||
    c == 0x0C ||
    c == 0x0B ||
    c == 0xA0 ||
    c == 0x3000;

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    (c >= 0x80 && !_isSpace(c));

/// Words, whitespace runs and single punctuation characters, keyed for
/// comparison under [options]. Whitespace the options ignore is left out.
List<_Token> _tokens(String s, CompareOptions options) {
  final out = <_Token>[];
  // Index of the last non-space character, for the trailing-space rule.
  var lastInk = s.length - 1;
  while (lastInk >= 0 && _isSpace(s.codeUnitAt(lastInk))) {
    lastInk--;
  }
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    var j = i + 1;
    if (_isSpace(c)) {
      while (j < s.length && _isSpace(s.codeUnitAt(j))) {
        j++;
      }
      final leading = i == 0, trailing = i > lastInk;
      final String? key = switch (options.whitespace) {
        WhitespaceMode.exact => s.substring(i, j),
        WhitespaceMode.trailing => trailing ? null : s.substring(i, j),
        WhitespaceMode.changes => leading || trailing ? null : ' ',
        WhitespaceMode.all => null,
      };
      if (key != null) out.add(_Token(key, i, j));
    } else {
      if (_isWordChar(c)) {
        while (j < s.length && _isWordChar(s.codeUnitAt(j))) {
          j++;
        }
      }
      final text = s.substring(i, j);
      out.add(_Token(options.ignoreCase ? text.toLowerCase() : text, i, j));
    }
    i = j;
  }
  return out;
}

/// Character-level common prefix/suffix trim of `a[sa, ea)` against
/// `b[sb, eb)`: highlights the middle part that actually changed.
(List<(int, int)>, List<(int, int)>) _trimSpans(
    String a, int sa, int ea, String b, int sb, int eb, bool ignoreCase) {
  bool same(int x, int y) {
    final p = a.codeUnitAt(x), q = b.codeUnitAt(y);
    if (p == q) return true;
    return ignoreCase &&
        String.fromCharCode(p).toLowerCase() ==
            String.fromCharCode(q).toLowerCase();
  }

  while (sa < ea && sb < eb && same(sa, sb)) {
    sa++;
    sb++;
  }
  while (ea > sa && eb > sb && same(ea - 1, eb - 1)) {
    ea--;
    eb--;
  }
  return (
    sa < ea ? [(sa, ea)] : <(int, int)>[],
    sb < eb ? [(sb, eb)] : <(int, int)>[],
  );
}

List<(int, int)> _mergeSpans(
    String s, List<(int, int)> spans, bool joinAcrossSpaces) {
  if (spans.length < 2) return spans;
  final out = <(int, int)>[spans.first];
  for (final span in spans.skip(1)) {
    final (start, end) = out.last;
    var gapIsSpace = span.$1 >= end;
    for (var i = end; gapIsSpace && i < span.$1; i++) {
      gapIsSpace = _isSpace(s.codeUnitAt(i));
    }
    if (span.$1 == end || (joinAcrossSpaces && gapIsSpace)) {
      out[out.length - 1] = (start, span.$2);
    } else {
      out.add(span);
    }
  }
  return out;
}
