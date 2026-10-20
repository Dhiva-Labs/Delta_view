/// Which entries a folder comparison leaves out: the user's ignore
/// patterns (from settings, plus any added for one comparison) and the
/// `.gitignore` files found in the compared trees.
///
/// Both use gitignore syntax: `*`, `?`, `[a-z]`, `**`, a leading `/` to
/// anchor a pattern to its folder, a trailing `/` for folders only, and a
/// leading `!` to take an entry back out of an earlier match.
library;

/// One compiled pattern line.
class IgnorePattern {
  IgnorePattern._(
    this._regex, {
    required this.source,
    required this.negated,
    required this.directoryOnly,
    required this.anchored,
  });

  /// The line as written.
  final String source;

  /// Started with `!`: a match re-includes the entry.
  final bool negated;

  /// Ended with `/`: matches folders only.
  final bool directoryOnly;

  /// Contained a `/` before its end, so it matches the path relative to
  /// the folder that holds the rules rather than a name at any depth.
  final bool anchored;

  final RegExp _regex;

  /// Parses one line. Returns null for blank lines and `#` comments.
  ///
  /// With [globstarMatchesDirectory], a pattern like `build/**` also
  /// matches the `build` folder itself, so the folder disappears instead
  /// of being shown empty. Gitignore files keep the strict meaning (only
  /// the contents match), which is what lets `!build/keep` work there.
  static IgnorePattern? parse(
    String line, {
    bool caseSensitive = true,
    bool globstarMatchesDirectory = false,
  }) {
    var text = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (text.isEmpty || text.startsWith('#')) return null;

    // Trailing spaces are dropped unless escaped with a backslash.
    var end = text.length;
    while (end > 0 && text[end - 1] == ' ') {
      if (end >= 2 && text[end - 2] == r'\') break;
      end--;
    }
    text = text.substring(0, end);

    var negated = false;
    if (text.startsWith('!')) {
      negated = true;
      text = text.substring(1);
    }
    var directoryOnly = false;
    if (text.endsWith('/') && !text.endsWith(r'\/')) {
      directoryOnly = true;
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) return null;

    final anchored = text.contains('/');
    if (text.startsWith('/')) text = text.substring(1);
    if (text.isEmpty) return null;

    final pattern = anchored
        ? _pathRegex(text, globstarMatchesDirectory)
        : '^${_segmentRegex(text)}\$';
    return IgnorePattern._(
      RegExp(pattern, caseSensitive: caseSensitive),
      source: line,
      negated: negated,
      directoryOnly: directoryOnly,
      anchored: anchored,
    );
  }

  /// Whether this pattern matches [path] (relative to the rules' folder,
  /// `/`-separated).
  bool matches(String path, {required bool isDirectory}) {
    if (directoryOnly && !isDirectory) return false;
    if (anchored) return _regex.hasMatch(path);
    final slash = path.lastIndexOf('/');
    return _regex.hasMatch(slash < 0 ? path : path.substring(slash + 1));
  }

  @override
  String toString() => source;

  /// A pattern with slashes, matched against the whole relative path.
  /// `**` as a whole segment spans any number of folders: a leading `**/`
  /// matches in every folder, `/**/` matches zero or more folders, and a
  /// trailing `/**` matches everything inside.
  static String _pathRegex(String text, bool globstarMatchesDirectory) {
    final segments = text.split('/');
    final n = segments.length;
    final out = StringBuffer('^');
    for (var i = 0; i < n; i++) {
      final segment = segments[i];
      final last = i == n - 1;
      if (segment == '**') {
        if (n == 1) {
          out.write('.*');
        } else if (last) {
          // The preceding segment already wrote its '/'. Rewind it when
          // the folder itself should match too.
          final soFar = out.toString();
          if (globstarMatchesDirectory && soFar.endsWith('/')) {
            out
              ..clear()
              ..write(soFar.substring(0, soFar.length - 1))
              ..write('(?:/.*)?');
          } else {
            out.write('.*');
          }
        } else {
          out.write('(?:.*/)?');
        }
      } else {
        out.write(_segmentRegex(segment));
        if (!last) out.write('/');
      }
    }
    out.write(r'$');
    return out.toString();
  }

  /// One path segment: `*` and `?` never cross a `/`, `[...]` is a
  /// character class (`[!...]` negated), `\x` is a literal x.
  static String _segmentRegex(String glob) {
    final out = StringBuffer();
    var i = 0;
    while (i < glob.length) {
      final c = glob[i];
      switch (c) {
        case '*':
          // Runs of asterisks inside a segment act like one.
          while (i + 1 < glob.length && glob[i + 1] == '*') {
            i++;
          }
          out.write('[^/]*');
        case '?':
          out.write('[^/]');
        case r'\':
          if (i + 1 < glob.length) {
            i++;
            out.write(RegExp.escape(glob[i]));
          } else {
            out.write(RegExp.escape(c));
          }
        case '[':
          final close = _classEnd(glob, i);
          if (close < 0) {
            out.write(RegExp.escape(c));
          } else {
            out.write(_classRegex(glob.substring(i + 1, close)));
            i = close;
          }
        default:
          out.write(RegExp.escape(c));
      }
      i++;
    }
    return out.toString();
  }

  /// Index of the `]` closing the class that opens at [open], or -1. A `]`
  /// right after `[` or `[!` is a literal member.
  static int _classEnd(String glob, int open) {
    var i = open + 1;
    if (i < glob.length && (glob[i] == '!' || glob[i] == '^')) i++;
    if (i < glob.length && glob[i] == ']') i++;
    while (i < glob.length) {
      if (glob[i] == r'\') {
        i += 2;
        continue;
      }
      if (glob[i] == ']') return i;
      i++;
    }
    return -1;
  }

  static String _classRegex(String body) {
    final out = StringBuffer('[');
    var i = 0;
    if (body.isNotEmpty && (body[0] == '!' || body[0] == '^')) {
      out.write('^/');
      i = 1;
    }
    for (; i < body.length; i++) {
      var c = body[i];
      if (c == r'\' && i + 1 < body.length) c = body[++i];
      if (c == '-' && i > 0 && i < body.length - 1) {
        out.write('-');
      } else if (r'\]^['.contains(c)) {
        out.write('\\$c');
      } else {
        out.write(c);
      }
    }
    out.write(']');
    return out.toString();
  }
}

/// An ordered list of patterns, as in one `.gitignore` file. The last
/// pattern that matches decides.
class IgnoreRuleSet {
  IgnoreRuleSet(this.patterns);

  /// Parses the text of an ignore file, one pattern per line.
  factory IgnoreRuleSet.parse(
    String text, {
    bool caseSensitive = true,
    bool globstarMatchesDirectory = false,
  }) =>
      IgnoreRuleSet.fromLines(text.split('\n'),
          caseSensitive: caseSensitive,
          globstarMatchesDirectory: globstarMatchesDirectory);

  factory IgnoreRuleSet.fromLines(
    Iterable<String> lines, {
    bool caseSensitive = true,
    bool globstarMatchesDirectory = false,
  }) =>
      IgnoreRuleSet([
        for (final line in lines)
          ?IgnorePattern.parse(line,
              caseSensitive: caseSensitive,
              globstarMatchesDirectory: globstarMatchesDirectory),
      ]);

  final List<IgnorePattern> patterns;

  bool get isEmpty => patterns.isEmpty;

  /// True when the last matching pattern ignores [path], false when it
  /// re-includes it, null when nothing matches.
  bool? decide(String path, {required bool isDirectory}) {
    for (var i = patterns.length - 1; i >= 0; i--) {
      final pattern = patterns[i];
      if (pattern.matches(path, isDirectory: isDirectory)) {
        return !pattern.negated;
      }
    }
    return null;
  }
}

/// The `.gitignore` files that apply inside one folder of one side: the
/// folder's own file, then its parents' up to the comparison root. Frames
/// are shared between sibling folders, so the chain costs nothing to pass
/// down the scan.
class GitignoreChain {
  const GitignoreChain._(this.base, this.rules, this.parent);

  /// [chain] plus the rules of the `.gitignore` in folder [base] (relative
  /// to the comparison root).
  static GitignoreChain push(
          GitignoreChain? chain, String base, IgnoreRuleSet rules) =>
      GitignoreChain._(base, rules, chain);

  final String base;
  final IgnoreRuleSet rules;
  final GitignoreChain? parent;

  /// Whether [path] (relative to the comparison root, inside [base]) is
  /// ignored. Deeper files override shallower ones, as in git.
  bool isIgnored(String path, {required bool isDirectory}) {
    for (GitignoreChain? frame = this; frame != null; frame = frame.parent) {
      final local = frame.base.isEmpty
          ? path
          : path.length > frame.base.length &&
                  path.startsWith(frame.base) &&
                  path.codeUnitAt(frame.base.length) == 0x2F
              ? path.substring(frame.base.length + 1)
              : null;
      if (local == null) continue;
      final decision = frame.rules.decide(local, isDirectory: isDirectory);
      if (decision != null) return decision;
    }
    return false;
  }
}

/// The user's patterns for one comparison: what settings say plus any
/// added just for this comparison. A pattern without a `/` matches a name
/// at any depth (`node_modules`, `*.pyc`); one with a `/` is anchored at
/// the comparison root (`build/**`, `/docs/drafts`).
class IgnoreRules {
  IgnoreRules(List<String> patterns, {this.caseSensitive = true})
      : global = IgnoreRuleSet.fromLines(patterns,
            caseSensitive: caseSensitive, globstarMatchesDirectory: true);

  final bool caseSensitive;
  final IgnoreRuleSet global;

  bool isIgnored(String path, {required bool isDirectory}) =>
      global.decide(path, isDirectory: isDirectory) ?? false;

  /// Whether [path] or any folder above it is ignored, for filtering file
  /// watcher events whose kind is not known.
  bool coversPath(String path) {
    if (global.isEmpty) return false;
    final parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final prefix = parts.sublist(0, i).join('/');
      if (isIgnored(prefix, isDirectory: true)) return true;
      if (i == parts.length && isIgnored(prefix, isDirectory: false)) {
        return true;
      }
    }
    return false;
  }

  /// Parses a `.gitignore` file's text with the same case rule.
  IgnoreRuleSet parseGitignore(String text) =>
      IgnoreRuleSet.parse(text, caseSensitive: caseSensitive);
}

/// A pattern matching exactly the entry at [path] (relative,
/// `/`-separated) and nothing else: anchored, with glob characters and a
/// trailing space escaped.
String exactPattern(String path) {
  var escaped = path.replaceAllMapped(RegExp(r'[*?[\\]'), (m) => '\\${m[0]}');
  if (escaped.endsWith(' ')) {
    escaped = '${escaped.substring(0, escaped.length - 1)}\\ ';
  }
  return '/$escaped';
}
