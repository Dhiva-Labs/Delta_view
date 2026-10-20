/// How a source line is painted in the diff panes: the editor font and
/// line metrics, tab expansion, whitespace markers, word wrapping, and the
/// layered styling (syntax colours, change emphasis, search matches).
///
/// Wrapping is done here rather than by the text engine, at known column
/// boundaries, so the height of every row is known without laying it out.
/// That keeps big wrapped files virtualised, and lets navigation, the
/// minimap and jump-to-line land on exact pixel offsets.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../theme.dart';
import 'syntax.dart';

/// Font and spacing of the text panes, from [AppSettings].
class EditorMetrics {
  EditorMetrics._({
    required this.style,
    required this.strut,
    required this.lineHeight,
    required this.charWidth,
    required this.tabAdvance,
    required this.tabWidth,
    required this.showWhitespace,
    required this.wrap,
    required this.syntax,
  });

  factory EditorMetrics.of(AppSettings s) {
    final key = (
      s.editorFontFamily,
      s.editorFontSize,
      s.editorLineHeight,
      s.tabWidth,
      s.showWhitespace,
      s.wordWrap,
      s.syntaxHighlighting,
    );
    final cached = _cache;
    if (cached != null && cached.$1 == key) return cached.$2;

    final fontSize = s.editorFontSize;
    // Whole pixels per line keep row edges crisp and the arithmetic exact.
    final lineHeight = (fontSize * s.editorLineHeight).roundToDouble();
    // Spacing is spelled out so a TextField does not inherit the theme's
    // body letter spacing, which would make its columns wider than the
    // ones measured here.
    final style = TextStyle(
      fontFamily: s.editorFontFamily,
      fontFamilyFallback: monoStyle.fontFamilyFallback,
      fontSize: fontSize,
      height: lineHeight / fontSize,
      letterSpacing: 0,
      wordSpacing: 0,
      fontWeight: FontWeight.w400,
    );
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final charWidth = measure('MMMMMMMMMMMMMMMMMMMM') / 20;
    final metrics = EditorMetrics._(
      style: style,
      strut: StrutStyle(
        fontFamily: s.editorFontFamily,
        fontFamilyFallback: monoStyle.fontFamilyFallback,
        fontSize: fontSize,
        height: lineHeight / fontSize,
        forceStrutHeight: true,
      ),
      lineHeight: lineHeight,
      charWidth: charWidth,
      tabAdvance: measure('M\tM') - 2 * charWidth,
      tabWidth: s.tabWidth,
      showWhitespace: s.showWhitespace,
      wrap: s.wordWrap,
      syntax: s.syntaxHighlighting,
    );
    _cache = (key, metrics);
    return metrics;
  }

  static (
    (String, double, double, int, bool, bool, bool),
    EditorMetrics
  )? _cache;

  final TextStyle style;

  /// Forces every line to exactly [lineHeight], whatever fallback fonts a
  /// line needs (emoji, CJK), so heights stay predictable.
  final StrutStyle strut;
  final double lineHeight;

  /// Advance of one column. Columns are what the panes count in; a
  /// proportional font makes this an estimate.
  final double charWidth;

  /// How wide the text engine draws a tab by itself; the editor widens it
  /// to the next tab stop.
  final double tabAdvance;

  final int tabWidth;
  final bool showWhitespace;
  final bool wrap;
  final bool syntax;

  double get fontSize => style.fontSize!;
}

/// Lines longer than this many columns are cut off in the panes (the rest
/// is still compared and saved): laying out a megabyte of minified code
/// per row would stall scrolling.
const maxDisplayColumns = 20000;

/// Columns a code unit takes: two for wide East Asian characters and
/// astral characters (emoji), none for combining marks and the second half
/// of a surrogate pair.
int charColumns(int c) {
  if (c < 0x0300) return 1;
  if (c <= 0x036F) return 0; // combining diacritics
  if (c < 0x1100) return 1;
  if (c >= 0xDC00 && c <= 0xDFFF) return 0; // low surrogate
  if (c >= 0xD800 && c <= 0xDBFF) return 2; // high surrogate
  if (c <= 0x115F ||
      (c >= 0x2E80 && c <= 0xA4CF && c != 0x303F) ||
      (c >= 0xAC00 && c <= 0xD7A3) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFE30 && c <= 0xFE4F) ||
      (c >= 0xFF00 && c <= 0xFF60) ||
      (c >= 0xFFE0 && c <= 0xFFE6)) {
    return 2;
  }
  return 1;
}

/// Display width of [source] in columns, with tabs expanded.
int displayColumns(String source, int tabWidth) {
  var col = 0;
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    col += c == 0x09 ? tabWidth - col % tabWidth : charColumns(c);
  }
  return col;
}

/// A source line laid out for display.
class DisplayLine {
  const DisplayLine(this.text, this.offsets, this.markers, this.breaks);

  /// The text as painted: tabs expanded, whitespace and control characters
  /// replaced by visible markers, no wrap breaks.
  final String text;

  /// For every source index (and the end), the index into [text].
  final Int32List offsets;

  /// 1 where [text] holds a marker glyph that should be dimmed.
  final Uint8List? markers;

  /// Indices into [text] where a new visual line starts when wrapped.
  final List<int> breaks;

  int get visualLines => breaks.length + 1;
}

bool _isLowSurrogate(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// Lays out [source] (without its line break) for display. With
/// [wrapColumns], breaks after whitespace where it can and mid-word where
/// a word alone is too long.
DisplayLine layoutLine(
  String source, {
  required int tabWidth,
  bool showWhitespace = false,
  int? wrapColumns,
}) {
  final out = StringBuffer();
  final offsets = Int32List(source.length + 1);
  final markers = <int>[];
  final breaks = <int>[];
  var length = 0; // of out
  var col = 0; // column in the whole line, for tab stops
  var lineCol = 0; // column within the current visual line
  var lastBreak = -1; // display index after the last whitespace
  var lastBreakCol = 0; // lineCol at lastBreak

  void emit(String piece, {bool marker = false}) {
    if (marker) {
      for (var k = 0; k < piece.length; k++) {
        markers.add(length + k);
      }
    }
    out.write(piece);
    length += piece.length;
  }

  var i = 0;
  for (; i < source.length; i++) {
    offsets[i] = length;
    if (col >= maxDisplayColumns) break;
    final c = source.codeUnitAt(i);
    final width = c == 0x09 ? tabWidth - col % tabWidth : charColumns(c);

    if (wrapColumns != null &&
        width > 0 &&
        lineCol > 0 &&
        lineCol + width > wrapColumns &&
        !_isLowSurrogate(c)) {
      final lineStart = breaks.isEmpty ? 0 : breaks.last;
      if (lastBreak > lineStart && lastBreak < length) {
        breaks.add(lastBreak);
        lineCol -= lastBreakCol;
      }
      if (lineCol > 0 && lineCol + width > wrapColumns) {
        breaks.add(length);
        lineCol = 0;
      }
      lastBreak = -1;
    }

    if (c == 0x09) {
      emit(showWhitespace ? '→' : ' ', marker: showWhitespace);
      if (width > 1) emit(' ' * (width - 1));
    } else if (c == 0x20) {
      emit(showWhitespace ? '·' : ' ', marker: showWhitespace);
    } else if (c < 0x20 || c == 0x7F) {
      // Control characters as their visible "control pictures".
      emit(String.fromCharCode(c == 0x7F ? 0x2421 : 0x2400 + c), marker: true);
    } else {
      emit(String.fromCharCode(c));
    }
    col += width;
    lineCol += width;
    if (c == 0x09 || c == 0x20) {
      lastBreak = length;
      lastBreakCol = lineCol;
    }
  }
  if (i < source.length) {
    // Cut off: every remaining source index maps to the end, after an
    // ellipsis that says there is more.
    emit(' …', marker: true);
    for (; i <= source.length; i++) {
      offsets[i] = length;
    }
  } else {
    offsets[source.length] = length;
  }
  Uint8List? markerMask;
  if (markers.isNotEmpty) {
    markerMask = Uint8List(length);
    for (final k in markers) {
      markerMask[k] = 1;
    }
  }
  return DisplayLine(out.toString(), offsets, markerMask, breaks);
}

/// A stretch `[start, end)` of a source line with one look.
class StyledRun {
  const StyledRun(this.start, this.end, this.style);

  final int start;
  final int end;
  final TextStyle? style;
}

/// Colours for the layers [styleRuns] combines.
class LineColors {
  const LineColors({
    required this.syntax,
    required this.match,
    required this.currentMatch,
    required this.marker,
  });

  factory LineColors.of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return LineColors(
      syntax: SyntaxColors.of(theme.brightness),
      match: dark ? const Color(0x55FACC15) : const Color(0x66FDE047),
      currentMatch: dark ? const Color(0xB3F59E0B) : const Color(0xCCFBBF24),
      marker: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
    );
  }

  final SyntaxColors syntax;
  final Color match;
  final Color currentMatch;

  /// Whitespace markers and other stand-in glyphs.
  final Color marker;
}

/// A search hit within one line.
typedef LineMatch = ({int start, int end, bool current});

/// Splits `[0, length)` into runs with one style each, layering search
/// matches over change emphasis (backgrounds) over syntax colours
/// (foregrounds).
List<StyledRun> styleRuns(
  int length, {
  List<SyntaxToken>? tokens,
  List<(int, int)>? emphasis,
  Color? emphasisColor,
  List<LineMatch>? matches,
  required LineColors colors,
}) {
  final cuts = <int>{0, length};
  for (final t in tokens ?? const <SyntaxToken>[]) {
    cuts
      ..add(t.start)
      ..add(t.end);
  }
  for (final (s, e) in emphasis ?? const <(int, int)>[]) {
    cuts
      ..add(s)
      ..add(e);
  }
  for (final m in matches ?? const <LineMatch>[]) {
    cuts
      ..add(m.start)
      ..add(m.end);
  }
  final sorted = cuts.where((c) => c >= 0 && c <= length).toList()..sort();

  final runs = <StyledRun>[];
  var ti = 0, ei = 0;
  for (var k = 0; k + 1 < sorted.length; k++) {
    final a = sorted[k], b = sorted[k + 1];
    if (a == b) continue;
    final ts = tokens ?? const <SyntaxToken>[];
    while (ti < ts.length && ts[ti].end <= a) {
      ti++;
    }
    final token = ti < ts.length && ts[ti].start <= a ? ts[ti] : null;
    final es = emphasis ?? const <(int, int)>[];
    while (ei < es.length && es[ei].$2 <= a) {
      ei++;
    }
    final emphasized = ei < es.length && es[ei].$1 <= a;
    LineMatch? match;
    for (final m in matches ?? const <LineMatch>[]) {
      if (m.start <= a && m.end > a) {
        match = m;
        if (m.current) break;
      }
    }

    final color = token == null ? null : colors.syntax.colorFor(token.cls);
    final background = match != null
        ? (match.current ? colors.currentMatch : colors.match)
        : emphasized
            ? emphasisColor
            : null;
    final italic = token != null && SyntaxColors.isItalic(token.cls);
    runs.add(StyledRun(
      a,
      b,
      color == null && background == null && !italic
          ? null
          : TextStyle(
              color: color,
              backgroundColor: background,
              fontStyle: italic ? FontStyle.italic : null,
            ),
    ));
  }
  return runs;
}

/// The painted text of a laid-out line: [runs] mapped onto [line]'s
/// display text, with wrap breaks as newlines and markers dimmed.
TextSpan displaySpan(
    DisplayLine line, List<StyledRun> runs, LineColors colors) {
  final children = <InlineSpan>[];
  final text = line.text;
  final markers = line.markers;
  final breaks = line.breaks;
  var nextBreak = 0;
  final markerStyle = TextStyle(color: colors.marker);

  void piece(int from, int to, TextStyle? style) {
    // Split at markers so they can be dimmed without losing the run's
    // background.
    var start = from;
    while (start < to) {
      final isMarker = markers != null && markers[start] == 1;
      var end = start + 1;
      while (end < to && (markers != null && markers[end] == 1) == isMarker) {
        end++;
      }
      children.add(TextSpan(
        text: text.substring(start, end),
        style: isMarker ? (style?.merge(markerStyle) ?? markerStyle) : style,
      ));
      start = end;
    }
  }

  void emit(int from, int to, TextStyle? style) {
    var start = from;
    while (nextBreak < breaks.length && breaks[nextBreak] <= start) {
      if (breaks[nextBreak] == start && start > 0) {
        children.add(const TextSpan(text: '\n'));
      }
      nextBreak++;
    }
    while (nextBreak < breaks.length && breaks[nextBreak] < to) {
      final at = breaks[nextBreak++];
      piece(start, at, style);
      children.add(const TextSpan(text: '\n'));
      start = at;
    }
    piece(start, to, style);
  }

  var covered = 0;
  for (final run in runs) {
    final from = line.offsets[run.start], to = line.offsets[run.end];
    if (to > from) emit(from, to, run.style);
    covered = to;
  }
  if (covered < text.length) emit(covered, text.length, null);
  return TextSpan(children: children);
}
