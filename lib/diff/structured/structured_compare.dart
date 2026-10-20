/// Parse-and-diff in one call, so the structured view can hand the whole
/// job to an isolate and get back plain results.
library;

import 'structured_parse.dart';
import 'table_diff.dart';
import 'tree_diff.dart';

export 'structured_parse.dart';
export 'table_diff.dart';
export 'tree_diff.dart';

sealed class StructuredOutcome {
  const StructuredOutcome();
}

class TreeOutcome extends StructuredOutcome {
  const TreeOutcome(this.result);

  final TreeDiffResult result;
}

class TableOutcome extends StructuredOutcome {
  const TableOutcome(this.diff);

  final TableDiff diff;
}

/// One side did not parse.
class ParseFailure extends StructuredOutcome {
  const ParseFailure({
    required this.leftSide,
    required this.format,
    required this.error,
  });

  final bool leftSide;
  final StructuredFormat format;
  final StructuredParseException error;
}

/// A table on one side and a tree on the other: no structure in common.
class FormatMismatch extends StructuredOutcome {
  const FormatMismatch(this.left, this.right);

  final StructuredFormat left;
  final StructuredFormat right;
}

/// Parses and diffs two texts. A null text is a missing file.
StructuredOutcome compareStructured({
  required String? leftText,
  required String? rightText,
  required StructuredFormat leftFormat,
  required StructuredFormat rightFormat,
  TreeDiffOptions treeOptions = const TreeDiffOptions(),
  TableDiffOptions tableOptions = const TableDiffOptions(),
}) {
  if (leftFormat.isTable != rightFormat.isTable) {
    return FormatMismatch(leftFormat, rightFormat);
  }
  try {
    if (leftFormat.isTable) {
      final l = _side(true, leftFormat,
          () => leftText == null ? null : parseTable(leftText, leftFormat));
      final r = _side(false, rightFormat,
          () => rightText == null ? null : parseTable(rightText, rightFormat));
      return TableOutcome(diffTables(l, r, tableOptions));
    }
    final l = _side(
        true,
        leftFormat,
        () =>
            leftText == null ? Absent.value : parseTree(leftText, leftFormat));
    final r = _side(
        false,
        rightFormat,
        () => rightText == null
            ? Absent.value
            : parseTree(rightText, rightFormat));
    return TreeOutcome(diffTrees(l, r, treeOptions));
  } on _SideFailure catch (f) {
    return f.failure;
  }
}

class _SideFailure implements Exception {
  const _SideFailure(this.failure);

  final ParseFailure failure;
}

T _side<T>(bool left, StructuredFormat format, T Function() parse) {
  try {
    return parse();
  } on StructuredParseException catch (e) {
    throw _SideFailure(ParseFailure(leftSide: left, format: format, error: e));
  }
}
