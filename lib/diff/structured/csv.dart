/// A small RFC 4180 CSV reader: quoted fields may hold delimiters, line
/// breaks and doubled quotes; any line ending works.
library;

class CsvParseException implements Exception {
  const CsvParseException(this.message, this.line, this.column);

  final String message;

  /// 1-based.
  final int line;
  final int column;

  @override
  String toString() => '$message (line $line, column $column)';
}

/// Picks the delimiter the first line uses most among comma, semicolon,
/// tab and pipe, ignoring quoted text. Commas win ties.
String sniffDelimiter(String text) {
  const candidates = [',', ';', '\t', '|'];
  final counts = {for (final c in candidates) c: 0};
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (!quoted) {
      if (c == '\n' || c == '\r') break;
      if (counts.containsKey(c)) counts[c] = counts[c]! + 1;
    }
  }
  var best = ',';
  for (final c in candidates) {
    if (counts[c]! > counts[best]!) best = c;
  }
  return best;
}

/// Splits [text] into records of fields. Blank lines are skipped. A quote
/// that is never closed is an error, reported where it opened; a quote in
/// the middle of an unquoted field is kept as an ordinary character, as
/// most spreadsheet programs do.
List<List<String>> parseCsv(String text, {String delimiter = ','}) {
  assert(delimiter.length == 1);
  final d = delimiter.codeUnitAt(0);
  const quote = 0x22, cr = 0x0D, lf = 0x0A;

  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var line = 1, lineStart = 0;
  var i = 0;
  // Whether the current record has any content yet (to skip blank lines).
  var started = false;

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    if (started) {
      endField();
      rows.add(row);
    }
    row = <String>[];
    field.clear();
    started = false;
  }

  // Consumes one line break at i (CRLF counts as one).
  void newline() {
    if (text.codeUnitAt(i) == cr &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == lf) {
      i++;
    }
    i++;
    line++;
    lineStart = i;
  }

  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == quote && field.isEmpty && _atFieldStart(text, i, d, lineStart)) {
      // A quoted field: read to the closing quote.
      started = true;
      final openLine = line, openColumn = i - lineStart + 1;
      i++;
      var closed = false;
      while (i < text.length) {
        final q = text.codeUnitAt(i);
        if (q == quote) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == quote) {
            field.writeCharCode(quote);
            i += 2;
            continue;
          }
          i++;
          closed = true;
          break;
        }
        if (q == cr || q == lf) {
          field.write(
              q == cr && i + 1 < text.length && text.codeUnitAt(i + 1) == lf
                  ? '\r\n'
                  : String.fromCharCode(q));
          newline();
          continue;
        }
        field.writeCharCode(q);
        i++;
      }
      if (!closed) {
        throw CsvParseException(
            'A quoted field is never closed', openLine, openColumn);
      }
      // Anything up to the next delimiter after the closing quote is kept.
      continue;
    }
    if (c == d) {
      started = true;
      endField();
      i++;
    } else if (c == cr || c == lf) {
      endRow();
      newline();
    } else {
      started = true;
      field.writeCharCode(c);
      i++;
    }
  }
  endRow();
  return rows;
}

/// Whether position [i] starts a field: the start of a line or right
/// after a delimiter.
bool _atFieldStart(String text, int i, int delimiter, int lineStart) =>
    i == lineStart || text.codeUnitAt(i - 1) == delimiter;
