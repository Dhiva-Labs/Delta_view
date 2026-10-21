/// Change blocks of a side-by-side diff with the lines they cover on each
/// side, and the edits that copy a block across or delete it: Meld's core
/// merge workflow.
library;

import 'edit_history.dart';
import 'line_diff.dart';

/// A run of changed rows, with the lines it covers on each side.
class ChangeBlock {
  const ChangeBlock({
    required this.firstRow,
    required this.endRow,
    required this.leftStart,
    required this.leftEnd,
    required this.rightStart,
    required this.rightEnd,
  });

  /// Rows `[firstRow, endRow)` of the [DiffResult].
  final int firstRow;
  final int endRow;

  /// Zero-based lines `[leftStart, leftEnd)` on the left. Empty for a pure
  /// insertion, in which case [leftStart] is the line it would go before.
  final int leftStart;
  final int leftEnd;

  final int rightStart;
  final int rightEnd;

  bool get hasLeft => leftEnd > leftStart;
  bool get hasRight => rightEnd > rightStart;

  DiffRowKind get kind => !hasLeft
      ? DiffRowKind.added
      : !hasRight
          ? DiffRowKind.removed
          : DiffRowKind.modified;

  bool containsRow(int row) => row >= firstRow && row < endRow;

  /// The lines on one side.
  (int, int) lines({required bool left}) =>
      left ? (leftStart, leftEnd) : (rightStart, rightEnd);
}

/// Every change block of [result], top to bottom (one per entry of
/// [DiffResult.changeBlocks]).
List<ChangeBlock> changeBlocksOf(DiffResult result) {
  final rows = result.rows;
  final out = <ChangeBlock>[];
  var leftSeen = 0, rightSeen = 0;
  var i = 0;
  while (i < rows.length) {
    final row = rows[i];
    if (row.kind == DiffRowKind.same) {
      if (row.leftNumber != null) leftSeen = row.leftNumber!;
      if (row.rightNumber != null) rightSeen = row.rightNumber!;
      i++;
      continue;
    }
    final first = i;
    final leftStart = leftSeen, rightStart = rightSeen;
    while (i < rows.length && rows[i].kind != DiffRowKind.same) {
      if (rows[i].leftNumber != null) leftSeen = rows[i].leftNumber!;
      if (rows[i].rightNumber != null) rightSeen = rows[i].rightNumber!;
      i++;
    }
    out.add(ChangeBlock(
      firstRow: first,
      endRow: i,
      leftStart: leftStart,
      leftEnd: leftSeen,
      rightStart: rightStart,
      rightEnd: rightSeen,
    ));
  }
  return out;
}

/// The edit that replaces lines `[start, end)` of [text] with [lines].
///
/// Works on whole lines and keeps whether [text] ends with a newline, so a
/// block copied from the middle of one file to the end of another does not
/// add or drop the final line break. [sourceEndsWithNewline] decides it
/// when [text] is empty. Returns null when nothing would change.
TextEdit? replaceLinesEdit(
  String text,
  int start,
  int end,
  List<String> lines, {
  bool sourceEndsWithNewline = true,
}) {
  final current = splitLines(text);
  final endsWithNewline =
      text.isEmpty ? sourceEndsWithNewline : text.endsWith('\n');
  final next = [
    ...current.sublist(0, start),
    ...lines,
    ...current.sublist(end),
  ];
  final result =
      next.isEmpty ? '' : next.join('\n') + (endsWithNewline ? '\n' : '');
  return TextEdit.between(text, result);
}

/// The edit to the target side that makes [block] read there as it does on
/// the source side: left → right when [toRight], else right → left.
TextEdit? copyBlockEdit(
  ChangeBlock block, {
  required String leftText,
  required String rightText,
  required bool toRight,
}) {
  final source = toRight ? leftText : rightText;
  final target = toRight ? rightText : leftText;
  final (srcStart, srcEnd) = block.lines(left: toRight);
  final (dstStart, dstEnd) = block.lines(left: !toRight);
  final lines = splitLines(source).sublist(srcStart, srcEnd);
  return replaceLinesEdit(target, dstStart, dstEnd, lines,
      sourceEndsWithNewline: source.endsWith('\n'));
}

/// The edit that removes [block]'s lines from one side.
TextEdit? deleteBlockEdit(ChangeBlock block, String text,
    {required bool left}) {
  final (start, end) = block.lines(left: left);
  if (start == end) return null;
  return replaceLinesEdit(text, start, end, const []);
}

/// Corresponding (left line, right line) positions at the start and end of
/// every block, plus both ends of the files. Between two anchors the sides
/// move together, so a scroll position on one side can be carried to the
/// other with [mapLine].
List<(double, double)> lineAnchors(
    List<ChangeBlock> blocks, int leftLines, int rightLines) {
  final out = <(double, double)>[(0, 0)];
  for (final b in blocks) {
    out.add((b.leftStart.toDouble(), b.rightStart.toDouble()));
    out.add((b.leftEnd.toDouble(), b.rightEnd.toDouble()));
  }
  out.add((leftLines.toDouble(), rightLines.toDouble()));
  return out;
}

/// Carries a fractional line position from one side to the other through
/// [anchors], interpolating linearly inside each stretch. Where the source
/// side has no lines (the other side inserted some), the position skips
/// past the insertion.
double mapLine(double line, List<(double, double)> anchors,
    {required bool fromLeft}) {
  double src((double, double) a) => fromLeft ? a.$1 : a.$2;
  double dst((double, double) a) => fromLeft ? a.$2 : a.$1;
  if (anchors.isEmpty) return line;
  // Last anchor at or before [line] (binary search; anchors are sorted on
  // both sides).
  var lo = 0, hi = anchors.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (src(anchors[mid]) <= line) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  final a = anchors[lo];
  if (lo + 1 >= anchors.length) return dst(a) + (line - src(a));
  final b = anchors[lo + 1];
  final span = src(b) - src(a);
  if (span <= 0) return dst(a);
  final t = ((line - src(a)) / span).clamp(0.0, 1.0);
  return dst(a) + t * (dst(b) - dst(a));
}
