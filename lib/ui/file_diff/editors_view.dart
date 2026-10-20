/// Edit mode: two free-form editors whose scrolling stays aligned through
/// the diff, joined by connecting bands, with line numbers and full-width
/// change backgrounds painted alongside.
///
/// The panes are not padded with filler lines here, so a line on the left
/// and its counterpart on the right sit at different heights. Scrolling
/// one side carries its top line across the diff's change blocks to the
/// other (see [mapLine]) instead of matching scroll percentages, which
/// drift apart as soon as the files differ in length.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../diff/change_blocks.dart';
import '../../diff/line_diff.dart';
import '../../theme.dart';
import 'connector_gutter.dart';
import 'diff_session.dart';
import 'line_layout.dart';
import 'minimap.dart';
import 'viewport.dart';

/// Texts longer than this are painted without syntax colours or change
/// emphasis while editing: the editor restyles the whole text on every
/// keystroke.
const _maxStyledLength = 1 << 20;
const _maxStyledLines = 20000;

class DiffEditorsView extends StatefulWidget {
  const DiffEditorsView({
    super.key,
    required this.session,
    required this.scrolls,
    required this.metrics,
    required this.currentBlock,
    required this.onCopy,
    required this.onDelete,
    this.onLayout,
  });

  final DiffSession session;

  /// Vertical scrolling of the left and right editors; owned by the parent
  /// so it can follow the scroll position from the first frame.
  final List<ScrollController> scrolls;
  final EditorMetrics metrics;
  final int currentBlock;
  final void Function(int index, {required bool toRight}) onCopy;
  final void Function(int index, {required bool left}) onDelete;

  /// Called after a frame that may have moved lines or blocks, for
  /// widgets outside that depend on their positions.
  final VoidCallback? onLayout;

  @override
  State<DiffEditorsView> createState() => DiffEditorsViewState();
}

class DiffEditorsViewState extends State<DiffEditorsView>
    implements DiffViewport {
  List<ScrollController> get scroll => widget.scrolls;
  late final _scrollListeners = [() => _onScroll(0), () => _onScroll(1)];
  final _hScroll = [ScrollController(), ScrollController()];
  final _fieldKeys = [GlobalKey(), GlobalKey()];
  final _editables = <RenderEditable?>[null, null];
  bool _syncing = false;
  bool _hSyncing = false;
  double _viewHeight = 0;
  late final Listenable _everything;

  /// Ticks when an editor's scroll metrics change without a scroll (text
  /// reflowed, position clamped), which its controller does not report.
  final _metricsTick = ValueNotifier<int>(0);

  DiffSession get _session => widget.session;
  EditorMetrics get _m => widget.metrics;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 2; i++) {
      scroll[i].addListener(_scrollListeners[i]);
      _hScroll[i].addListener(() => _onHScroll(i));
      _session.sides[i].controller.spanBuilder =
          (context, text, style) => _spans(i, context, text, style);
    }
    _everything = Listenable.merge([
      ...scroll,
      _metricsTick,
      for (final s in _session.sides) s.controller,
    ]);
  }

  @override
  void dispose() {
    _metricsTick.dispose();
    for (var i = 0; i < 2; i++) {
      _session.sides[i].controller.spanBuilder = null;
      scroll[i].removeListener(_scrollListeners[i]);
      _hScroll[i].dispose();
    }
    super.dispose();
  }

  // ---- geometry ----

  /// The editor's text render object, found below the field.
  RenderEditable? _editable(int side) {
    final cached = _editables[side];
    if (cached != null && cached.attached) return cached;
    RenderEditable? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderEditable) {
        found = o;
      } else {
        o.visitChildren(visit);
      }
    }

    final root = _fieldKeys[side].currentContext?.findRenderObject();
    if (root != null) visit(root);
    return _editables[side] = found;
  }

  /// Top of [line] on [side] in content coordinates (unscrolled). Lines
  /// past the end sit just below the last one.
  ///
  /// Without wrapping every line is exactly one strut high. With it, the
  /// text engine knows where a line starts; its caret rectangle is offset
  /// from the line top by a constant, which measuring line 0 cancels out.
  double lineTop(int side, int line) {
    final lh = _m.lineHeight;
    if (line <= 0) return 0;
    if (!_m.wrap) return line * lh;
    final re = _editable(side);
    if (re == null || !re.hasSize) return line * lh;
    final text = _session.sides[side].text;
    final starts = _session.lineStarts(side);
    final count = starts.length - 1;
    final offset = line < count ? starts[line] : text.length;
    try {
      final base = re.getLocalRectForCaret(const TextPosition(offset: 0)).top;
      final y =
          re.getLocalRectForCaret(TextPosition(offset: offset)).top - base;
      var top = (y / lh).round() * lh;
      // The end of a last line without a newline is on that line; what
      // comes after it starts one line further down.
      if (line >= count && text.isNotEmpty && !text.endsWith('\n')) top += lh;
      return top;
    } catch (_) {
      return line * lh;
    }
  }

  double _contentY(int side, double line) {
    final k = line.floor();
    final top = lineTop(side, k);
    final f = line - k;
    return f == 0 ? top : top + f * (lineTop(side, k + 1) - top);
  }

  /// The (fractional) line at the top of [side]'s view.
  double topLine(int side) {
    final s = scroll[side];
    if (!s.hasClients) return 0;
    final y = s.offset, lh = _m.lineHeight;
    if (!_m.wrap) return y / lh;
    final re = _editable(side);
    if (re == null || !re.hasSize) return y / lh;
    final position =
        re.getPositionForPoint(re.localToGlobal(const Offset(2, 1)));
    var k = _session.lineAt(side, position.offset);
    var top = lineTop(side, k);
    while (k > 0 && top > y) {
      top = lineTop(side, --k);
    }
    final next = lineTop(side, k + 1);
    return k + (next > top ? ((y - top) / (next - top)).clamp(0.0, 1.0) : 0.0);
  }

  void _onScroll(int side) {
    if (_syncing) return;
    final other = 1 - side;
    if (!scroll[side].hasClients || !scroll[other].hasClients) return;
    final mapped =
        mapLine(topLine(side), _session.anchors, fromLeft: side == 0);
    final y = _contentY(other, mapped)
        .clamp(0.0, scroll[other].position.maxScrollExtent);
    _syncing = true;
    try {
      scroll[other].jumpTo(y);
    } finally {
      _syncing = false;
    }
  }

  void _onHScroll(int side) {
    if (_hSyncing) return;
    final other = _hScroll[1 - side];
    if (!_hScroll[side].hasClients || !other.hasClients) return;
    _hSyncing = true;
    try {
      other.jumpTo(
          _hScroll[side].offset.clamp(0.0, other.position.maxScrollExtent));
    } finally {
      _hSyncing = false;
    }
  }

  // ---- DiffViewport ----

  @override
  Listenable get scrollListenable => scroll[0];

  @override
  double get scrollTop => scroll[0].hasClients ? scroll[0].offset : 0;

  @override
  double get viewHeight => _viewHeight;

  @override
  double blockTop(int index) => lineTop(0, _session.blocks[index].leftStart);

  @override
  void revealBlock(int index) {
    final block = _session.blocks[index];
    // Reveal on the side that has lines; the other follows.
    final side = block.hasLeft || !block.hasRight ? 0 : 1;
    revealLine(side, block.lines(left: side == 0).$1);
  }

  /// Scrolls [line] of [side] to just below the top. With [select], also
  /// selects that range of the side's text; with [focus], moves the
  /// keyboard focus there.
  void revealLine(int side, int line,
      {TextSelection? select,
      bool focus = false,
      bool animate = true,
      double? margin}) {
    final s = scroll[side];
    if (s.hasClients) {
      final target =
          (lineTop(side, line) - (margin ?? revealMargin(_viewHeight)))
              .clamp(0.0, s.position.maxScrollExtent);
      if (animate) {
        s.animateTo(target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic);
      } else {
        s.jumpTo(target);
      }
    }
    final model = _session.sides[side];
    if (select != null) {
      model.controller.selection = select;
      if (!_m.wrap && _hScroll[side].hasClients) {
        final starts = _session.lineStarts(side);
        final lineStart = starts[math.min(line, starts.length - 1)];
        final before = model.text.substring(lineStart,
            math.max(lineStart, math.min(select.start, model.text.length)));
        final x = displayColumns(before, _m.tabWidth) * _m.charWidth;
        final h = _hScroll[side];
        final view = h.position.viewportDimension;
        if (x < h.offset || x > h.offset + view - 40) {
          h.jumpTo(math
              .max(0.0, x - view / 3)
              .clamp(0.0, h.position.maxScrollExtent));
        }
      }
    }
    if (focus) model.focusNode.requestFocus();
  }

  /// The change block under the caret of the focused editor.
  int? blockAtCursor() {
    for (var side = 0; side < 2; side++) {
      final model = _session.sides[side];
      if (!model.focusNode.hasFocus) continue;
      final selection = model.controller.selection;
      if (!selection.isValid) return null;
      final line = _session.lineAt(side, selection.baseOffset);
      final blocks = _session.blocks;
      for (var i = 0; i < blocks.length; i++) {
        final (start, end) = blocks[i].lines(left: side == 0);
        if (line >= start && (line < end || (start == end && line == start))) {
          return i;
        }
        if (start > line) break;
      }
    }
    return null;
  }

  // ---- painting the text ----

  TextSpan _spans(
      int side, BuildContext context, String text, TextStyle? style) {
    if (text.length > _maxStyledLength) {
      return TextSpan(text: text, style: style);
    }
    final lines = text.split('\n');
    if (lines.length > _maxStyledLines) {
      return TextSpan(text: text, style: style);
    }
    final colors = LineColors.of(context);
    final palette = DiffPalette.of(context);
    final highlighter = _m.syntax ? _session.highlighter : null;
    final rows = _session.result?.rows;
    final rowOf = _session.rowOfLine[side];
    final hits = _session.matchesByLine[side];
    final current = _session.currentFindMatch;
    final emphasisColor =
        side == 0 ? palette.removedEmphasis : palette.addedEmphasis;
    final children = <InlineSpan>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final last = i == lines.length - 1;
      List<(int, int)>? emphasis;
      if (rows != null && i < rowOf.length) {
        final row = rows[rowOf[i]];
        final shown = side == 0 ? row.leftText : row.rightText;
        // Only while the diff still describes this line.
        if (row.kind == DiffRowKind.modified &&
            shown != null &&
            (shown == line || shown == '$line\r')) {
          emphasis = side == 0 ? row.leftSpans : row.rightSpans;
        }
      }
      final lineHits = hits[i];
      final hasTab = line.contains('\t');
      if (highlighter == null &&
          emphasis == null &&
          lineHits == null &&
          !hasTab) {
        children.add(TextSpan(text: last ? line : '$line\n'));
        continue;
      }
      final runs = styleRuns(
        line.length,
        tokens: highlighter?.tokens(line),
        emphasis: emphasis,
        emphasisColor: emphasisColor,
        matches: lineHits == null
            ? null
            : [
                for (final h in lineHits)
                  (start: h.start, end: h.end, current: identical(h, current)),
              ],
        colors: colors,
      );
      _addRuns(children, line, runs, hasTab);
      if (!last) children.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: style, children: children);
  }

  /// Adds [runs] of [line], widening each tab to the next tab stop: the
  /// text engine draws a tab as one narrow space, and the editor cannot
  /// expand tabs into spaces without changing the text.
  void _addRuns(
      List<InlineSpan> out, String line, List<StyledRun> runs, bool hasTab) {
    if (!hasTab) {
      for (final run in runs) {
        out.add(TextSpan(
            text: line.substring(run.start, run.end), style: run.style));
      }
      return;
    }
    final tab = _m.tabWidth;
    var col = 0;
    for (final run in runs) {
      var start = run.start;
      for (var j = run.start; j < run.end; j++) {
        final c = line.codeUnitAt(j);
        if (c != 0x09) {
          col += charColumns(c);
          continue;
        }
        if (j > start) {
          out.add(TextSpan(text: line.substring(start, j), style: run.style));
        }
        final stop = tab - col % tab;
        out.add(TextSpan(
          text: '\t',
          style: (run.style ?? const TextStyle())
              .copyWith(letterSpacing: stop * _m.charWidth - _m.tabAdvance),
        ));
        col += stop;
        start = j + 1;
      }
      if (start < run.end) {
        out.add(
            TextSpan(text: line.substring(start, run.end), style: run.style));
      }
    }
  }

  // ---- layout ----

  final _maxCols = <(String, int)?>[null, null];

  int _maxColumns(int side) {
    final text = _session.sides[side].text;
    final cached = _maxCols[side];
    if (cached != null && identical(cached.$1, text)) return cached.$2;
    var max = 0;
    var start = 0;
    while (start <= text.length) {
      var end = text.indexOf('\n', start);
      if (end < 0) end = text.length;
      // A line can only be wider if it has enough characters, counting
      // the widest a character can be (a tab).
      if ((end - start) * math.max(2, _m.tabWidth) > max) {
        max = math.max(
            max, displayColumns(text.substring(start, end), _m.tabWidth));
      }
      start = end + 1;
    }
    _maxCols[side] = (text, max);
    return max;
  }

  double _numberWidth() {
    final lines = math.max(_session.lineCount(0), _session.lineCount(1));
    final digits = math.max(3, '$lines'.length);
    return (digits + 2) * _m.charWidth * 0.86 + 10;
  }

  /// The blocks that can be seen on either side.
  List<int> _visibleBlocks() {
    final blocks = _session.blocks;
    if (blocks.isEmpty || _viewHeight <= 0) return const [];
    final span = (_viewHeight / _m.lineHeight).ceil() + 1;
    final lTop = topLine(0).floor(), rTop = topLine(1).floor();
    final lBottom = lTop + span, rBottom = rTop + span;
    var lo = 0, hi = blocks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (blocks[mid].leftEnd >= lTop || blocks[mid].rightEnd >= rTop) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return [
      for (var i = lo;
          i < blocks.length &&
              (blocks[i].leftStart <= lBottom ||
                  blocks[i].rightStart <= rBottom);
          i++)
        i,
    ];
  }

  double _y(int side, int line) =>
      lineTop(side, line) - (scroll[side].hasClients ? scroll[side].offset : 0);

  bool _onMetrics(ScrollMetricsNotification notification) {
    _metricsTick.value++;
    widget.onLayout?.call();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final onLayout = widget.onLayout;
    if (onLayout != null) {
      // Text edits move lines without changing any scroll metrics.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onLayout();
      });
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: _layout(),
    );
  }

  Widget _layout() {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth - Minimap.width;
      final paneWidth = (width - ConnectorGutter.width) / 2;
      _viewHeight = constraints.maxHeight;
      final numberWidth = _numberWidth();
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
              width: paneWidth,
              child: _pane(
                  context, 0, paneWidth, numberWidth, constraints.maxHeight)),
          SizedBox(
            width: ConnectorGutter.width,
            child: AnimatedBuilder(
              animation: _everything,
              builder: (context, _) => ConnectorGutter(
                bands: [
                  for (final i in _visibleBlocks())
                    BandGeometry(
                      index: i,
                      block: _session.blocks[i],
                      leftTop: _y(0, _session.blocks[i].leftStart),
                      leftBottom: _y(0, _session.blocks[i].leftEnd),
                      rightTop: _y(1, _session.blocks[i].rightStart),
                      rightBottom: _y(1, _session.blocks[i].rightEnd),
                    ),
                ],
                currentBlock: widget.currentBlock,
                onCopy: widget.onCopy,
                onDelete: widget.onDelete,
              ),
            ),
          ),
          SizedBox(
              width: paneWidth,
              child: _pane(
                  context, 1, paneWidth, numberWidth, constraints.maxHeight)),
          AnimatedBuilder(
            animation: _everything,
            builder: (context, _) {
              final top = topLine(0);
              return Minimap(
                // A file shorter than the view is not stretched to fill it.
                total: math.max(_session.lineCount(0).toDouble(),
                    _viewHeight / _m.lineHeight),
                marks: [
                  for (final b in _session.blocks)
                    (
                      start: b.leftStart.toDouble(),
                      end: math.max(b.leftEnd.toDouble(), b.leftStart + 0.3),
                      kind: b.kind,
                    ),
                ],
                viewStart: top,
                viewExtent: _viewHeight / _m.lineHeight,
                onScrollTo: (line) {
                  final s = scroll[0];
                  if (!s.hasClients) return;
                  s.jumpTo(_contentY(
                          0, line.clamp(0.0, _session.lineCount(0).toDouble()))
                      .clamp(0.0, s.position.maxScrollExtent));
                },
              );
            },
          ),
        ],
      );
    });
  }

  Widget _pane(BuildContext context, int side, double width, double numberWidth,
      double height) {
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final model = _session.sides[side];
    final textWidth = width - numberWidth;
    final field = CallbackShortcuts(
      // Tab types a tab instead of moving the focus.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.tab): () {
          final c = model.controller;
          if (c.selection.isValid) {
            c.value = c.value.replaced(c.selection, '\t');
          }
        },
      },
      child: TextField(
        key: _fieldKeys[side],
        controller: model.controller,
        focusNode: model.focusNode,
        scrollController: scroll[side],
        maxLines: null,
        expands: true,
        style: _m.style.copyWith(color: scheme.onSurface),
        strutStyle: _m.strut,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        cursorWidth: 1.6,
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: EdgeInsets.only(left: 6, right: 16),
        ),
      ),
    );
    final contentWidth = _m.wrap
        ? textWidth
        // Generous, so the editor never wraps a line on its own: its line
        // positions are computed assuming it does not.
        : math.max(textWidth, _maxColumns(side) * _m.charWidth * 1.05 + 64);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: numberWidth,
          child: CustomPaint(
            painter: _LineNumberPainter(
              view: this,
              side: side,
              repaint: _everything,
              style: _m.style.copyWith(
                fontSize: _m.fontSize * 0.86,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              palette: palette,
              markerWidth: _m.charWidth * 1.6,
            ),
          ),
        ),
        SizedBox(
          width: textWidth,
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BackgroundPainter(
                  view: this,
                  side: side,
                  repaint: _everything,
                  palette: palette,
                  currentBlock: widget.currentBlock,
                ),
              ),
            ),
            Positioned.fill(
              child: _m.wrap
                  ? field
                  : SingleChildScrollView(
                      controller: _hScroll[side],
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                          width: contentWidth, height: height, child: field),
                    ),
            ),
          ]),
        ),
      ],
    );
  }
}

/// Full-width backgrounds for the change blocks on one side; a single
/// line marks where the other side inserted lines.
class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({
    required this.view,
    required this.side,
    required super.repaint,
    required this.palette,
    required this.currentBlock,
  });

  final DiffEditorsViewState view;
  final int side;
  final DiffPalette palette;
  final int currentBlock;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final blocks = view._session.blocks;
    final left = side == 0;
    final paint = Paint();
    for (final i in view._visibleBlocks()) {
      final b = blocks[i];
      final (start, end) = b.lines(left: left);
      final top = view._y(side, start);
      if (start == end) {
        paint.color = (left ? palette.added : palette.removed)
            .withValues(alpha: i == currentBlock ? 0.9 : 0.6);
        canvas.drawRect(Rect.fromLTWH(0, top - 1, size.width, 2), paint);
        continue;
      }
      final bottom = view._y(side, end);
      paint.color = palette.rowBackground(b.kind == DiffRowKind.modified
          ? DiffRowKind.modified
          : left
              ? DiffRowKind.removed
              : DiffRowKind.added);
      canvas.drawRect(Rect.fromLTRB(0, top, size.width, bottom), paint);
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => true;
}

/// Line numbers for the visible lines, with the same + / − / ~ markers as
/// view mode.
class _LineNumberPainter extends CustomPainter {
  _LineNumberPainter({
    required this.view,
    required this.side,
    required super.repaint,
    required this.style,
    required this.palette,
    required this.markerWidth,
  });

  final DiffEditorsViewState view;
  final int side;
  final TextStyle style;
  final DiffPalette palette;
  final double markerWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final session = view._session;
    final count = math.max(1, session.lineCount(side));
    final rows = session.result?.rows;
    final rowOf = session.rowOfLine[side];
    final lh = view._m.lineHeight;
    canvas.clipRect(Offset.zero & size);
    for (var line = math.max(0, view.topLine(side).floor());
        line < count;
        line++) {
      final y = view._y(side, line);
      if (y > size.height) break;
      if (y + lh < 0) continue;
      var marker = '';
      Color? markerColor;
      if (rows != null && line < rowOf.length) {
        switch (rows[rowOf[line]].kind) {
          case DiffRowKind.same:
            break;
          case DiffRowKind.modified:
            (marker, markerColor) = ('~', palette.modified);
          case DiffRowKind.removed:
            (marker, markerColor) = ('−', palette.removed);
          case DiffRowKind.added:
            (marker, markerColor) = ('+', palette.added);
        }
      }
      final number = TextPainter(
        text: TextSpan(text: '${line + 1}', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final dy = y + (lh - number.height) / 2;
      number.paint(canvas, Offset(size.width - markerWidth - number.width, dy));
      number.dispose();
      if (marker.isNotEmpty) {
        final m = TextPainter(
          text: TextSpan(
              text: marker,
              style: style.copyWith(
                  color: markerColor, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        m.paint(canvas,
            Offset(size.width - markerWidth + (markerWidth - m.width) / 2, dy));
        m.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_LineNumberPainter old) => true;
}
