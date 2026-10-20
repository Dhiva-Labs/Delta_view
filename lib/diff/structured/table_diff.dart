/// Row-by-row comparison of two tables (CSV / TSV), matching rows by a key
/// column rather than by position, so reordered rows are not changes.
///
/// Pure Dart; runs in an isolate for big tables.
library;

enum RowStatus { same, added, removed, changed }

enum ColumnStatus { same, added, removed }

class TableDiffOptions {
  const TableDiffOptions({this.header = true, this.keyColumn = 0});

  /// The first row names the columns. Columns then match by name, so a
  /// moved column is not a change.
  final bool header;

  /// Index into [TableDiff.columns] of the column rows are matched by.
  final int keyColumn;

  TableDiffOptions copyWith({bool? header, int? keyColumn}) => TableDiffOptions(
        header: header ?? this.header,
        keyColumn: keyColumn ?? this.keyColumn,
      );
}

class RowDiff {
  const RowDiff({
    required this.status,
    required this.key,
    required this.left,
    required this.right,
    this.changedColumns = const {},
    this.leftRow,
    this.rightRow,
  });

  final RowStatus status;
  final String key;

  /// Cell per [TableDiff.columns]; null where the row or the column is
  /// missing on that side.
  final List<String?> left;
  final List<String?> right;

  /// Columns (indexes into [TableDiff.columns]) whose values differ.
  final Set<int> changedColumns;

  /// 1-based record numbers in each file, counting the header.
  final int? leftRow;
  final int? rightRow;
}

class TableDiff {
  const TableDiff({
    required this.columns,
    required this.columnStatus,
    required this.rows,
    required this.keyColumn,
    required this.header,
  });

  final List<String> columns;
  final List<ColumnStatus> columnStatus;
  final List<RowDiff> rows;
  final int keyColumn;
  final bool header;

  int count(RowStatus status) => rows.where((r) => r.status == status).length;

  int get changedCells =>
      rows.fold(0, (sum, r) => sum + r.changedColumns.length);
}

/// Compares two parsed tables ([parseTable] output; null for a missing
/// file). Rows match by the value in the key column; when a key repeats,
/// its first occurrence on the left matches its first on the right, and
/// so on.
TableDiff diffTables(List<List<String>>? left, List<List<String>>? right,
    [TableDiffOptions options = const TableDiffOptions()]) {
  final l = left ?? const <List<String>>[];
  final r = right ?? const <List<String>>[];

  // Columns: by header name, or by position.
  final List<String> columns;
  final List<int?> leftCol, rightCol;
  if (options.header) {
    final ln = _uniqueNames(l.isEmpty ? const [] : l.first);
    final rn = _uniqueNames(r.isEmpty ? const [] : r.first);
    columns = [
      ...ln,
      for (final n in rn)
        if (!ln.contains(n)) n
    ];
    leftCol = [for (final c in columns) _indexOrNull(ln, c)];
    rightCol = [for (final c in columns) _indexOrNull(rn, c)];
  } else {
    var width = 0;
    for (final row in [...l, ...r]) {
      if (row.length > width) width = row.length;
    }
    columns = [for (var i = 0; i < width; i++) 'Column ${i + 1}'];
    int widthOf(List<List<String>> rows) =>
        rows.fold(0, (w, row) => row.length > w ? row.length : w);
    final lw = widthOf(l), rw = widthOf(r);
    leftCol = [for (var i = 0; i < width; i++) i < lw ? i : null];
    rightCol = [for (var i = 0; i < width; i++) i < rw ? i : null];
  }
  final columnStatus = [
    for (var c = 0; c < columns.length; c++)
      leftCol[c] == null
          ? ColumnStatus.added
          : rightCol[c] == null
              ? ColumnStatus.removed
              : ColumnStatus.same,
  ];

  final key =
      columns.isEmpty ? 0 : options.keyColumn.clamp(0, columns.length - 1);
  final skip = options.header ? 1 : 0;
  final lRows = l.length > skip ? l.sublist(skip) : const <List<String>>[];
  final rRows = r.length > skip ? r.sublist(skip) : const <List<String>>[];

  List<String?> cells(List<String> row, List<int?> map) => [
        for (final i in map) i == null ? null : (i < row.length ? row[i] : ''),
      ];
  String keyOf(List<String?> cells) => cells.isEmpty ? '' : (cells[key] ?? '');

  final lCells = [for (final row in lRows) cells(row, leftCol)];
  final rCells = [for (final row in rRows) cells(row, rightCol)];

  // Left rows by key, in order, for first-come matching of repeats.
  final byKey = <String, List<int>>{};
  for (var i = 0; i < lCells.length; i++) {
    (byKey[keyOf(lCells[i])] ??= []).add(i);
  }
  final used = <String, int>{};
  final matchOf = List<int?>.filled(rCells.length, null);
  final matchedLeft = <int>{};
  for (var j = 0; j < rCells.length; j++) {
    final k = keyOf(rCells[j]);
    final candidates = byKey[k];
    final n = used[k] ?? 0;
    if (candidates != null && n < candidates.length) {
      matchOf[j] = candidates[n];
      matchedLeft.add(candidates[n]);
      used[k] = n + 1;
    }
  }

  RowDiff rowDiff(int? li, int? ri) {
    final lc =
        li == null ? List<String?>.filled(columns.length, null) : lCells[li];
    final rc =
        ri == null ? List<String?>.filled(columns.length, null) : rCells[ri];
    final changed = <int>{};
    if (li != null && ri != null) {
      for (var c = 0; c < columns.length; c++) {
        if (lc[c] != null && rc[c] != null && lc[c] != rc[c]) changed.add(c);
      }
    }
    return RowDiff(
      status: li == null
          ? RowStatus.added
          : ri == null
              ? RowStatus.removed
              : changed.isEmpty
                  ? RowStatus.same
                  : RowStatus.changed,
      key: keyOf(li == null ? rc : lc),
      left: lc,
      right: rc,
      changedColumns: changed,
      leftRow: li == null ? null : li + skip + 1,
      rightRow: ri == null ? null : ri + skip + 1,
    );
  }

  // Right's order; a removed row follows the left row it came after.
  final after = <int, List<int>>{};
  final leading = <int>[];
  int? anchor;
  for (var i = 0; i < lCells.length; i++) {
    if (matchedLeft.contains(i)) {
      anchor = i;
    } else if (anchor == null) {
      leading.add(i);
    } else {
      (after[anchor] ??= []).add(i);
    }
  }
  final rows = <RowDiff>[
    for (final i in leading) rowDiff(i, null),
  ];
  for (var j = 0; j < rCells.length; j++) {
    final li = matchOf[j];
    rows.add(rowDiff(li, j));
    if (li != null) {
      for (final i in after[li] ?? const <int>[]) {
        rows.add(rowDiff(i, null));
      }
    }
  }

  return TableDiff(
    columns: columns,
    columnStatus: columnStatus,
    rows: rows,
    keyColumn: key,
    header: options.header,
  );
}

/// Header names, with repeats made distinct (`name`, `name (2)`) so each
/// column can still be matched by name.
List<String> _uniqueNames(List<String> header) {
  final seen = <String, int>{};
  return [
    for (final raw in header)
      () {
        final name = raw.isEmpty ? '(blank)' : raw;
        final n = (seen[name] ?? 0) + 1;
        seen[name] = n;
        return n == 1 ? name : '$name ($n)';
      }(),
  ];
}

int? _indexOrNull(List<String> names, String name) {
  final i = names.indexOf(name);
  return i < 0 ? null : i;
}
