/// Command-line arguments: `delta-view LEFT RIGHT` compares two folders or
/// two files, `--merge` opens a three-way merge, and `--help` / `--version`
/// print and exit. Parsing is pure (the file system is injected) so it is
/// unit-tested without touching disk.
library;

import '../compare/comparison.dart';
import '../ui/brand/app_info.dart';
import 'user_paths.dart';

/// What `main` should do with the arguments it was given.
class LaunchRequest {
  const LaunchRequest({
    this.comparisons = const [],
    this.problems = const [],
    this.output,
    this.exitCode = 0,
  });

  /// Opened as the first tabs, in order.
  final List<Comparison> comparisons;

  /// Friendly messages about arguments that could not be turned into a
  /// comparison. Shown in the app, not thrown.
  final List<String> problems;

  /// Text to print to stdout before exiting with [exitCode] (`--help`,
  /// `--version`). Null means start the app.
  final String? output;

  final int exitCode;

  bool get exitsEarly => output != null;
}

/// Answers "what is at this path" for the parser. The default looks at the
/// real file system; tests use a map.
abstract class PathProbe {
  const PathProbe();

  PathKind kindOf(String path);

  /// Expands `~` and makes the path absolute.
  String resolve(String path);
}

class IoPathProbe extends PathProbe {
  const IoPathProbe();

  @override
  PathKind kindOf(String path) => pathKindOf(path);

  @override
  String resolve(String path) => expandUserPath(path);
}

const usageText = '''
$appName $appVersion — compare folders and files side by side.

Usage:
  delta-view                                   open the home screen
  delta-view LEFT RIGHT                        compare two folders or two files
  delta-view --merge LOCAL BASE REMOTE [--output MERGED]
                                               resolve a three-way merge

Options:
  -m, --merge          treat the three paths as LOCAL BASE REMOTE
  -o, --output FILE    where the merged result is written (with --merge);
                       without it the merge is saved over LOCAL
  -h, --help           show this help and exit
  -V, --version        print the version and exit

Paths may be relative, and may start with ~. Folders are compared as
trees and files side by side; which one is picked from what is on disk.
See docs/command-line.md for git difftool and mergetool setup.''';

LaunchRequest parseLaunchArgs(List<String> args,
    {PathProbe probe = const IoPathProbe()}) {
  var merge = false;
  String? output;
  final positional = <String>[];
  final problems = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') {
      positional.addAll(args.sublist(i + 1));
      break;
    }
    if (!arg.startsWith('-') || arg == '-') {
      positional.add(arg);
      continue;
    }
    switch (arg) {
      case '-h' || '--help':
        return const LaunchRequest(output: usageText);
      case '-V' || '-v' || '--version':
        return const LaunchRequest(output: '$appName $appVersion');
      case '-m' || '--merge':
        merge = true;
      case '-o' || '--output':
        if (i + 1 >= args.length) {
          problems.add('$arg needs a file path after it.');
        } else {
          output = args[++i];
        }
      default:
        if (arg.startsWith('--output=')) {
          output = arg.substring('--output='.length);
        } else {
          problems.add('Unknown option $arg. Try delta-view --help.');
        }
    }
  }

  final comparisons = <Comparison>[];
  if (merge) {
    _parseMerge(positional, output, probe, comparisons, problems);
  } else {
    if (output != null) {
      problems.add('--output only makes sense together with --merge.');
    }
    _parsePair(positional, probe, comparisons, problems);
  }
  return LaunchRequest(comparisons: comparisons, problems: problems);
}

void _parsePair(List<String> positional, PathProbe probe,
    List<Comparison> comparisons, List<String> problems) {
  if (positional.isEmpty) return;
  if (positional.length != 2) {
    problems.add(positional.length == 1
        ? 'Only one path was given (${positional.single}). '
            'Pass two folders or two files to compare them.'
        : '${positional.length} paths were given; pass exactly two to '
            'compare them, or use --merge for a three-way merge.');
    return;
  }
  final left = probe.resolve(positional[0]);
  final right = probe.resolve(positional[1]);
  final leftKind = probe.kindOf(left);
  final rightKind = probe.kindOf(right);
  final missing = [
    if (leftKind == PathKind.missing) left,
    if (rightKind == PathKind.missing) right,
  ];
  if (missing.isNotEmpty) {
    problems.add(missing.length == 1
        ? 'Nothing was found at ${missing.single}.'
        : 'Nothing was found at ${missing[0]} or ${missing[1]}.');
    return;
  }
  if (leftKind != rightKind) {
    final (folder, file) =
        leftKind == PathKind.directory ? (left, right) : (right, left);
    problems.add('$folder is a folder but $file is a file. '
        'Compare two folders or two files.');
    return;
  }
  comparisons.add(leftKind == PathKind.directory
      ? FolderComparison(LocalSource(left), LocalSource(right))
      : FileComparison(LocalSource(left), LocalSource(right)));
}

void _parseMerge(List<String> positional, String? output, PathProbe probe,
    List<Comparison> comparisons, List<String> problems) {
  if (positional.length != 3) {
    problems.add('--merge needs three files: LOCAL BASE REMOTE '
        '(${positional.length} given).');
    return;
  }
  final resolved = [for (final s in positional) probe.resolve(s)];
  final folders = [
    for (final path in resolved)
      if (probe.kindOf(path) == PathKind.directory) path,
  ];
  if (folders.isNotEmpty) {
    problems.add('${folders.first} is a folder; a merge needs three files.');
    return;
  }
  // The base may be missing (git uses an empty base for added files) and
  // the output is created on save, so only LOCAL and REMOTE must exist.
  final missing = [
    for (final path in [resolved[0], resolved[2]])
      if (probe.kindOf(path) == PathKind.missing) path,
  ];
  if (missing.isNotEmpty) {
    problems.add('Nothing was found at ${missing.join(' or ')}.');
    return;
  }
  comparisons.add(ThreeWayComparison(
    left: LocalSource(resolved[0]),
    base: LocalSource(resolved[1]),
    right: LocalSource(resolved[2]),
    output: output == null ? null : LocalSource(probe.resolve(output)),
  ));
}
