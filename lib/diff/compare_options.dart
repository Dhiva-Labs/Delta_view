/// Rules that decide which differences count. Used by the line diff, the
/// folder scanner (when it decides whether two text files are "the same"),
/// and stored in settings as the default for new comparisons.
library;

enum WhitespaceMode {
  /// Every whitespace character matters.
  exact,

  /// Trailing whitespace at the end of a line is ignored.
  trailing,

  /// Runs of whitespace compare equal to a single space, and leading and
  /// trailing whitespace is ignored.
  changes,

  /// All whitespace is ignored.
  all,
}

class CompareOptions {
  const CompareOptions({
    this.whitespace = WhitespaceMode.exact,
    this.ignoreCase = false,
    this.ignoreLineEndings = true,
    this.ignoreBlankLines = false,
  });

  final WhitespaceMode whitespace;
  final bool ignoreCase;

  /// CRLF and LF compare equal.
  final bool ignoreLineEndings;

  /// Lines that are empty (after the whitespace rule) are left out of the
  /// comparison.
  final bool ignoreBlankLines;

  static const exact = CompareOptions(ignoreLineEndings: false);

  bool get isExact =>
      whitespace == WhitespaceMode.exact &&
      !ignoreCase &&
      !ignoreLineEndings &&
      !ignoreBlankLines;

  /// The key a line is compared by under these options. Two lines are equal
  /// when their keys are equal; the original text is still what is shown.
  String normalize(String line) {
    var s = line;
    if (ignoreLineEndings && s.endsWith('\r')) {
      s = s.substring(0, s.length - 1);
    }
    switch (whitespace) {
      case WhitespaceMode.exact:
        break;
      case WhitespaceMode.trailing:
        s = s.trimRight();
      case WhitespaceMode.changes:
        s = s.trim().replaceAll(_whitespaceRun, ' ');
      case WhitespaceMode.all:
        s = s.replaceAll(_whitespaceRun, '');
    }
    if (ignoreCase) s = s.toLowerCase();
    return s;
  }

  static final _whitespaceRun = RegExp(r'\s+');

  /// Whether [line] drops out of the comparison under [ignoreBlankLines].
  bool isIgnoredBlank(String line) =>
      ignoreBlankLines && normalize(line).trim().isEmpty;

  /// The rules that are switched on, in a few words each, e.g.
  /// `['trailing whitespace', 'case']`. Empty when nothing is ignored.
  List<String> get ignoredParts => [
        switch (whitespace) {
          WhitespaceMode.exact => null,
          WhitespaceMode.trailing => 'trailing whitespace',
          WhitespaceMode.changes => 'whitespace changes',
          WhitespaceMode.all => 'all whitespace',
        },
        if (ignoreCase) 'case',
        if (ignoreLineEndings) 'line endings',
        if (ignoreBlankLines) 'blank lines',
      ].nonNulls.toList();

  /// One short line for status bars, e.g. `Ignoring case, line endings`.
  String get summary {
    final parts = ignoredParts;
    return parts.isEmpty ? 'Exact compare' : 'Ignoring ${parts.join(', ')}';
  }

  CompareOptions copyWith({
    WhitespaceMode? whitespace,
    bool? ignoreCase,
    bool? ignoreLineEndings,
    bool? ignoreBlankLines,
  }) =>
      CompareOptions(
        whitespace: whitespace ?? this.whitespace,
        ignoreCase: ignoreCase ?? this.ignoreCase,
        ignoreLineEndings: ignoreLineEndings ?? this.ignoreLineEndings,
        ignoreBlankLines: ignoreBlankLines ?? this.ignoreBlankLines,
      );

  Map<String, Object?> toJson() => {
        'whitespace': whitespace.name,
        'ignoreCase': ignoreCase,
        'ignoreLineEndings': ignoreLineEndings,
        'ignoreBlankLines': ignoreBlankLines,
      };

  factory CompareOptions.fromJson(Map<String, Object?> json) => CompareOptions(
        whitespace: WhitespaceMode.values.asNameMap()[json['whitespace']] ??
            WhitespaceMode.exact,
        ignoreCase: json['ignoreCase'] == true,
        ignoreLineEndings: json['ignoreLineEndings'] != false,
        ignoreBlankLines: json['ignoreBlankLines'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is CompareOptions &&
      other.whitespace == whitespace &&
      other.ignoreCase == ignoreCase &&
      other.ignoreLineEndings == ignoreLineEndings &&
      other.ignoreBlankLines == ignoreBlankLines;

  @override
  int get hashCode =>
      Object.hash(whitespace, ignoreCase, ignoreLineEndings, ignoreBlankLines);
}
