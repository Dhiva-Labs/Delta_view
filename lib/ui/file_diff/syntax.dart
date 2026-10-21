/// Syntax highlighting for the diff panes, one line at a time.
///
/// Lines are highlighted lazily as they scroll into view and cached by
/// their text, so a big file costs nothing until it is looked at and a
/// line that appears on both sides is parsed once. Highlighting a line on
/// its own cannot see a block comment or string that started on an earlier
/// line; for a diff, where the eye follows short stretches, that trade is
/// worth the speed.
library;

import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart' show Highlight, Mode, Node;
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/clojure.dart';
import 'package:highlight/languages/cmake.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/cs.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/dos.dart';
import 'package:highlight/languages/elixir.dart';
import 'package:highlight/languages/erlang.dart';
import 'package:highlight/languages/fsharp.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/gradle.dart';
import 'package:highlight/languages/graphql.dart';
import 'package:highlight/languages/groovy.dart';
import 'package:highlight/languages/haskell.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/julia.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/less.dart';
import 'package:highlight/languages/lua.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/nginx.dart';
import 'package:highlight/languages/objectivec.dart';
import 'package:highlight/languages/ocaml.dart';
import 'package:highlight/languages/perl.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/properties.dart';
import 'package:highlight/languages/protobuf.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/r.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scala.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/shell.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/tex.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/vbnet.dart';
import 'package:highlight/languages/vim.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:path/path.dart' as p;

/// A highlighted stretch of one line: `[start, end)` with an
/// highlight.js class such as `keyword` or `string`.
class SyntaxToken {
  const SyntaxToken(this.start, this.end, this.cls);

  final int start;
  final int end;
  final String cls;
}

/// Files bigger than this are not highlighted at all.
const maxHighlightedLines = 100000;

/// Lines longer than this are left plain: the regex-driven parser can take
/// a long time on minified code.
const _maxHighlightedLineLength = 2000;

/// Languages by lower-case file extension (or whole file name).
final Map<String, (String, Mode Function())> _languages = {
  for (final e in ['dart']) e: ('dart', () => dart),
  for (final e in ['js', 'mjs', 'cjs', 'jsx'])
    e: ('javascript', () => javascript),
  for (final e in ['ts', 'tsx', 'mts', 'cts'])
    e: ('typescript', () => typescript),
  for (final e in ['py', 'pyw', 'pyi']) e: ('python', () => python),
  for (final e in ['java']) e: ('java', () => java),
  for (final e in ['kt', 'kts']) e: ('kotlin', () => kotlin),
  for (final e in ['swift']) e: ('swift', () => swift),
  for (final e in ['c', 'h', 'cc', 'cpp', 'cxx', 'hpp', 'hh', 'hxx', 'ino'])
    e: ('cpp', () => cpp),
  for (final e in ['m', 'mm']) e: ('objectivec', () => objectivec),
  for (final e in ['cs']) e: ('cs', () => cs),
  for (final e in ['fs', 'fsx', 'fsi']) e: ('fsharp', () => fsharp),
  for (final e in ['vb']) e: ('vbnet', () => vbnet),
  for (final e in ['go']) e: ('go', () => go),
  for (final e in ['rs']) e: ('rust', () => rust),
  for (final e in ['rb', 'rake', 'gemspec']) e: ('ruby', () => ruby),
  for (final e in ['php']) e: ('php', () => php),
  for (final e in ['pl', 'pm']) e: ('perl', () => perl),
  for (final e in ['lua']) e: ('lua', () => lua),
  for (final e in ['r']) e: ('r', () => r),
  for (final e in ['jl']) e: ('julia', () => julia),
  for (final e in ['scala', 'sc']) e: ('scala', () => scala),
  for (final e in ['groovy']) e: ('groovy', () => groovy),
  for (final e in ['gradle']) e: ('gradle', () => gradle),
  for (final e in ['hs']) e: ('haskell', () => haskell),
  for (final e in ['ml', 'mli']) e: ('ocaml', () => ocaml),
  for (final e in ['ex', 'exs']) e: ('elixir', () => elixir),
  for (final e in ['erl', 'hrl']) e: ('erlang', () => erlang),
  for (final e in ['clj', 'cljs', 'cljc', 'edn']) e: ('clojure', () => clojure),
  for (final e in ['sh', 'bash', 'zsh', 'ksh']) e: ('bash', () => bash),
  for (final e in ['ps1', 'psm1']) e: ('powershell', () => powershell),
  for (final e in ['bat', 'cmd']) e: ('dos', () => dos),
  for (final e in ['json', 'jsonc', 'arb']) e: ('json', () => json),
  for (final e in ['yaml', 'yml']) e: ('yaml', () => yaml),
  for (final e in [
    'xml',
    'html',
    'htm',
    'xhtml',
    'svg',
    'plist',
    'xsd',
    'xaml'
  ])
    e: ('xml', () => xml),
  for (final e in ['css']) e: ('css', () => css),
  for (final e in ['scss', 'sass']) e: ('scss', () => scss),
  for (final e in ['less']) e: ('less', () => less),
  for (final e in ['md', 'markdown']) e: ('markdown', () => markdown),
  for (final e in ['sql']) e: ('sql', () => sql),
  for (final e in ['ini', 'cfg', 'conf', 'toml', 'desktop', 'service'])
    e: ('ini', () => ini),
  for (final e in ['properties']) e: ('properties', () => properties),
  for (final e in ['proto']) e: ('protobuf', () => protobuf),
  for (final e in ['graphql', 'gql']) e: ('graphql', () => graphql),
  for (final e in ['tex', 'sty', 'cls']) e: ('tex', () => tex),
  for (final e in ['vim']) e: ('vim', () => vim),
  for (final e in ['diff', 'patch']) e: ('diff', () => diff),
  for (final e in ['cmake']) e: ('cmake', () => cmake),
  // Whole file names.
  'makefile': ('makefile', () => makefile),
  'gnumakefile': ('makefile', () => makefile),
  'dockerfile': ('dockerfile', () => dockerfile),
  'cmakelists.txt': ('cmake', () => cmake),
  'nginx.conf': ('nginx', () => nginx),
  '.bashrc': ('bash', () => bash),
  '.zshrc': ('bash', () => bash),
  '.profile': ('shell', () => shell),
};

final _engine = Highlight();
final _registered = <String>{};

class SyntaxHighlighter {
  SyntaxHighlighter._(this.language);

  /// The highlighter for a file called [name], or null when its language
  /// is not known.
  static SyntaxHighlighter? forFile(String name) {
    final base = p.basename(name).toLowerCase();
    final ext = p.extension(base);
    final entry = _languages[base] ??
        (ext.length > 1 ? _languages[ext.substring(1)] : null);
    if (entry == null) return null;
    final (language, mode) = entry;
    if (_registered.add(language)) _engine.registerLanguage(language, mode());
    return _cache.putIfAbsent(language, () => SyntaxHighlighter._(language));
  }

  static final _cache = <String, SyntaxHighlighter>{};

  /// highlight.js language id, e.g. `dart`.
  final String language;

  // Map literals keep insertion order, so the oldest entries go first.
  final _lines = <String, List<SyntaxToken>>{};
  static const _maxCachedLines = 6000;

  /// The tokens of [line], computed on first use.
  List<SyntaxToken> tokens(String line) {
    final cached = _lines.remove(line);
    if (cached != null) {
      _lines[line] = cached; // most recently used
      return cached;
    }
    final tokens = _tokenize(line);
    _lines[line] = tokens;
    if (_lines.length > _maxCachedLines) _lines.remove(_lines.keys.first);
    return tokens;
  }

  List<SyntaxToken> _tokenize(String line) {
    if (line.isEmpty || line.length > _maxHighlightedLineLength) {
      return const [];
    }
    try {
      final nodes = _engine.parse(line, language: language).nodes;
      if (nodes == null) return const [];
      final out = <SyntaxToken>[];
      var offset = 0;
      void walk(Node node, String? cls) {
        final own = node.className ?? cls;
        final value = node.value;
        if (value != null) {
          if (own != null && value.isNotEmpty) {
            out.add(SyntaxToken(offset, offset + value.length, own));
          }
          offset += value.length;
        }
        for (final child in node.children ?? const <Node>[]) {
          walk(child, own);
        }
      }

      for (final node in nodes) {
        walk(node, null);
      }
      // The parser is meant to reproduce the line exactly; drop anything
      // that does not line up rather than paint the wrong characters.
      return offset == line.length ? out : const [];
    } catch (_) {
      return const [];
    }
  }
}

/// Token colours that read on both the light and the dark theme and stay
/// clear of the diff's own green / red / amber, so a coloured keyword is
/// never mistaken for a change.
class SyntaxColors {
  const SyntaxColors._(this._colors, this.comment);

  final Map<String, Color> _colors;
  final Color comment;

  static SyntaxColors of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  Color? colorFor(String cls) {
    if (cls == 'comment' || cls == 'quote' || cls == 'doctag') return comment;
    return _colors[cls] ?? _colors[cls.split('-').first];
  }

  static bool isItalic(String cls) =>
      cls == 'comment' || cls == 'quote' || cls == 'emphasis';

  static const _light = SyntaxColors._({
    'keyword': Color(0xFF7C3AED),
    'selector': Color(0xFF7C3AED),
    'built_in': Color(0xFF0369A1),
    'type': Color(0xFF0369A1),
    'class': Color(0xFF0369A1),
    'literal': Color(0xFF1D4ED8),
    'number': Color(0xFF1D4ED8),
    'symbol': Color(0xFF1D4ED8),
    'string': Color(0xFF9A3412),
    'regexp': Color(0xFF9A3412),
    'subst': Color(0xFF334155),
    'title': Color(0xFF6D28D9),
    'function': Color(0xFF6D28D9),
    'section': Color(0xFF6D28D9),
    'meta': Color(0xFF64748B),
    'attr': Color(0xFF0E7490),
    'attribute': Color(0xFF0E7490),
    'variable': Color(0xFF0E7490),
    'template': Color(0xFF0E7490),
    'params': Color(0xFF334155),
    'tag': Color(0xFF0369A1),
    'name': Color(0xFF0369A1),
    'bullet': Color(0xFF7C3AED),
    'link': Color(0xFF1D4ED8),
  }, Color(0xFF6B7280));

  static const _dark = SyntaxColors._({
    'keyword': Color(0xFFC4B5FD),
    'selector': Color(0xFFC4B5FD),
    'built_in': Color(0xFF7DD3FC),
    'type': Color(0xFF7DD3FC),
    'class': Color(0xFF7DD3FC),
    'literal': Color(0xFF93C5FD),
    'number': Color(0xFF93C5FD),
    'symbol': Color(0xFF93C5FD),
    'string': Color(0xFFFDBA74),
    'regexp': Color(0xFFFDBA74),
    'subst': Color(0xFFE2E8F0),
    'title': Color(0xFFDDD6FE),
    'function': Color(0xFFDDD6FE),
    'section': Color(0xFFDDD6FE),
    'meta': Color(0xFF94A3B8),
    'attr': Color(0xFF67E8F9),
    'attribute': Color(0xFF67E8F9),
    'variable': Color(0xFF67E8F9),
    'template': Color(0xFF67E8F9),
    'params': Color(0xFFE2E8F0),
    'tag': Color(0xFF7DD3FC),
    'name': Color(0xFF7DD3FC),
    'bullet': Color(0xFFC4B5FD),
    'link': Color(0xFF93C5FD),
  }, Color(0xFF8B95A5));
}
