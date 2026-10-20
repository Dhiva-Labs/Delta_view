/// Unified diff output (`diff -u` / `git diff` style) for "Copy as unified
/// diff" and "Save patch…".
library;

import 'dart:math' as math;

import 'line_diff.dart';

/// A unified diff of [leftText] → [rightText] with `---` / `+++` headers
/// naming [leftName] and [rightName], and [context] lines of context
/// around each hunk. Empty when the texts are the same under [options].
///
/// Lines are written as they are, including a trailing `\r`, so a patch of
/// CRLF files applies to CRLF files. A side without a final newline gets
/// the usual `\ No newline at end of file` marker.
String unifiedDiff(
  String leftText,
  String rightText, {
  String leftName = 'a',
  String rightName = 'b',
  int context = 3,
  CompareOptions options = CompareOptions.exact,
}) {
  return unifiedDiffFromRows(
    buildSideBySide(leftText, rightText, options: options).rows,
    leftName: leftName,
    rightName: rightName,
    context: context,
    leftHasFinalNewline: leftText.isEmpty || leftText.endsWith('\n'),
    rightHasFinalNewline: rightText.isEmpty || rightText.endsWith('\n'),
  );
}

/// [unifiedDiff] over rows that were already computed.
String unifiedDiffFromRows(
  List<DiffRow> rows, {
  required String leftName,
  required String rightName,
  int context = 3,
  bool leftHasFinalNewline = true,
  bool rightHasFinalNewline = true,
}) {
  // Rows that make a hunk: real changes. Rows with only one side (blank
  // lines an option ignored) are not changes, but inside a hunk they must
  // still be written as - or + for the patch to apply.
  // When only one side ends without a newline, its last line differs even
  // if the text matches.
  final lastIsChange = leftHasFinalNewline != rightHasFinalNewline &&
      rows.isNotEmpty &&
      rows.last.leftNumber != null &&
      rows.last.rightNumber != null;
  bool isChange(int i) =>
      rows[i].kind != DiffRowKind.same ||
      (lastIsChange && i == rows.length - 1);
  final changed = <int>[
    for (var i = 0; i < rows.length; i++)
      if (isChange(i)) i,
  ];
  if (changed.isEmpty) return '';

  // Group changes whose context would touch into one hunk: [start, end).
  final hunks = <(int, int)>[];
  for (final i in changed) {
    final start = math.max(0, i - context);
    final end = math.min(rows.length, i + 1 + context);
    if (hunks.isNotEmpty && start <= hunks.last.$2) {
      hunks[hunks.length - 1] = (hunks.last.$1, end);
    } else {
      hunks.add((start, end));
    }
  }

  final lastLeft = rows.lastIndexWhere((r) => r.leftNumber != null);
  final lastRight = rows.lastIndexWhere((r) => r.rightNumber != null);
  const noNewline = r'\ No newline at end of file';

  final out = StringBuffer()
    ..writeln('--- $leftName')
    ..writeln('+++ $rightName');
  for (final (start, end) in hunks) {
    // Line numbers where the hunk starts on each side, and line counts.
    var leftFrom = 0, rightFrom = 0, leftCount = 0, rightCount = 0;
    for (var i = 0; i < start; i++) {
      if (rows[i].leftNumber != null) leftFrom = rows[i].leftNumber!;
      if (rows[i].rightNumber != null) rightFrom = rows[i].rightNumber!;
    }
    final body = StringBuffer();
    final removed = <int>[], added = <int>[];

    void flushChange() {
      for (final i in removed) {
        body.writeln('-${rows[i].leftText}');
        if (i == lastLeft && !leftHasFinalNewline) body.writeln(noNewline);
      }
      for (final i in added) {
        body.writeln('+${rows[i].rightText}');
        if (i == lastRight && !rightHasFinalNewline) body.writeln(noNewline);
      }
      removed.clear();
      added.clear();
    }

    for (var i = start; i < end; i++) {
      final row = rows[i];
      final hasLeft = row.leftNumber != null,
          hasRight = row.rightNumber != null;
      if (hasLeft) leftCount++;
      if (hasRight) rightCount++;
      if (!isChange(i) && hasLeft && hasRight) {
        flushChange();
        body.writeln(' ${row.leftText}');
        // A context line that is the last on both sides; if only one side
        // lacks the final newline the line would be a change instead.
        if (i == lastLeft && !leftHasFinalNewline) body.writeln(noNewline);
        continue;
      }
      if (hasLeft) removed.add(i);
      if (hasRight) added.add(i);
    }
    flushChange();

    String range(int from, int count) {
      // An empty range names the line before it, as diff does.
      final first = count == 0 ? from : from + 1;
      return count == 1 ? '$first' : '$first,$count';
    }

    out
      ..writeln('@@ -${range(leftFrom, leftCount)} '
          '+${range(rightFrom, rightCount)} @@')
      ..write(body);
  }
  return out.toString();
}
