import 'package:delta_view/cli/launch_args.dart';
import 'package:delta_view/cli/user_paths.dart';
import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/ui/brand/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// A file system described by a map, so parsing never touches disk.
class FakeProbe extends PathProbe {
  FakeProbe(this.kinds);

  final Map<String, PathKind> kinds;

  @override
  PathKind kindOf(String path) => kinds[path] ?? PathKind.missing;

  @override
  String resolve(String path) =>
      expandUserPath(path, home: '/home/u', cwd: '/work');
}

void main() {
  final probe = FakeProbe({
    '/a': PathKind.directory,
    '/b': PathKind.directory,
    '/a/x.txt': PathKind.file,
    '/b/x.txt': PathKind.file,
    '/work/rel.txt': PathKind.file,
    '/home/u/notes.txt': PathKind.file,
    '/m/local': PathKind.file,
    '/m/base': PathKind.file,
    '/m/remote': PathKind.file,
  });

  group('parseLaunchArgs', () {
    test('no arguments opens nothing', () {
      final r = parseLaunchArgs([], probe: probe);
      expect(r.comparisons, isEmpty);
      expect(r.problems, isEmpty);
      expect(r.exitsEarly, isFalse);
    });

    test('two folders become a folder comparison', () {
      final r = parseLaunchArgs(['/a', '/b'], probe: probe);
      expect(r.problems, isEmpty);
      final c = r.comparisons.single as FolderComparison;
      expect(c.left, const LocalSource('/a'));
      expect(c.right, const LocalSource('/b'));
    });

    test('two files become a file comparison', () {
      final r = parseLaunchArgs(['/a/x.txt', '/b/x.txt'], probe: probe);
      expect(r.comparisons.single, isA<FileComparison>());
    });

    test('relative paths and ~ are resolved', () {
      final r = parseLaunchArgs(['rel.txt', '~/notes.txt'], probe: probe);
      final c = r.comparisons.single as FileComparison;
      expect(c.left, const LocalSource('/work/rel.txt'));
      expect(c.right, const LocalSource('/home/u/notes.txt'));
    });

    test('a folder and a file is reported, not opened', () {
      final r = parseLaunchArgs(['/a', '/a/x.txt'], probe: probe);
      expect(r.comparisons, isEmpty);
      expect(r.problems.single, contains('/a is a folder'));
      expect(r.problems.single, contains('/a/x.txt is a file'));
    });

    test('missing paths are named in the message', () {
      final r = parseLaunchArgs(['/a', '/nope'], probe: probe);
      expect(r.comparisons, isEmpty);
      expect(r.problems.single, 'Nothing was found at /nope.');

      final both = parseLaunchArgs(['/no1', '/no2'], probe: probe);
      expect(both.problems.single, contains('/no1 or /no2'));
    });

    test('one or three plain paths explain what is expected', () {
      expect(parseLaunchArgs(['/a'], probe: probe).problems.single,
          contains('Only one path'));
      expect(parseLaunchArgs(['/a', '/b', '/a'], probe: probe).problems.single,
          contains('exactly two'));
    });

    test('--merge opens a three-way comparison without an output', () {
      final r = parseLaunchArgs(['--merge', '/m/local', '/m/base', '/m/remote'],
          probe: probe);
      expect(r.problems, isEmpty);
      final c = r.comparisons.single as ThreeWayComparison;
      expect(c.left, const LocalSource('/m/local'));
      expect(c.base, const LocalSource('/m/base'));
      expect(c.right, const LocalSource('/m/remote'));
      expect(c.output, isNull);
    });

    test('--output and --output= set the merge result', () {
      for (final args in [
        ['-m', '/m/local', '/m/base', '/m/remote', '-o', '/m/out'],
        ['--merge', '/m/local', '/m/base', '/m/remote', '--output', 'out'],
        ['--merge', '--output=/m/out', '/m/local', '/m/base', '/m/remote'],
      ]) {
        final r = parseLaunchArgs(args, probe: probe);
        expect(r.problems, isEmpty, reason: args.join(' '));
        final c = r.comparisons.single as ThreeWayComparison;
        expect(c.output, isNotNull);
      }
      final relative = parseLaunchArgs(
          ['--merge', '/m/local', '/m/base', '/m/remote', '--output', 'out'],
          probe: probe);
      expect((relative.comparisons.single as ThreeWayComparison).output,
          const LocalSource('/work/out'));
    });

    test('a merge may have a missing base but not a missing side', () {
      final noBase = parseLaunchArgs(
          ['--merge', '/m/local', '/m/gone', '/m/remote'],
          probe: probe);
      expect(noBase.comparisons, hasLength(1));

      final noRemote = parseLaunchArgs(
          ['--merge', '/m/local', '/m/base', '/m/gone'],
          probe: probe);
      expect(noRemote.comparisons, isEmpty);
      expect(noRemote.problems.single, contains('/m/gone'));
    });

    test('--merge with the wrong count or a folder is reported', () {
      expect(parseLaunchArgs(['--merge', '/m/local', '/m/base'], probe: probe)
          .problems
          .single, contains('three files'));
      expect(parseLaunchArgs(['--merge', '/a', '/m/base', '/m/remote'],
              probe: probe)
          .problems
          .single, contains('/a is a folder'));
    });

    test('--output without --merge and unknown options are reported', () {
      final r = parseLaunchArgs(['--output', 'x', '/a', '/b'], probe: probe);
      expect(r.problems.single, contains('--output only makes sense'));
      expect(r.comparisons, hasLength(1), reason: 'the pair still opens');

      final unknown = parseLaunchArgs(['--bogus', '/a', '/b'], probe: probe);
      expect(unknown.problems.single, contains('Unknown option --bogus'));
    });

    test('-o at the end without a value is reported', () {
      final r = parseLaunchArgs(['--merge', '/m/local', '/m/base', '/m/remote', '-o'],
          probe: probe);
      expect(r.problems.single, contains('-o needs a file path'));
    });

    test('-- ends option parsing', () {
      final r = parseLaunchArgs(['--', '/a', '/b'], probe: probe);
      expect(r.comparisons.single, isA<FolderComparison>());
    });

    test('--help prints the usage and exits', () {
      for (final flag in ['--help', '-h']) {
        final r = parseLaunchArgs([flag, '/a', '/b'], probe: probe);
        expect(r.exitsEarly, isTrue);
        expect(r.exitCode, 0);
        expect(r.output, contains('Usage:'));
        expect(r.output, contains('--merge'));
      }
    });

    test('--version prints the name and version', () {
      for (final flag in ['--version', '-V', '-v']) {
        final r = parseLaunchArgs([flag], probe: probe);
        expect(r.exitsEarly, isTrue);
        expect(r.output, '$appName $appVersion');
      }
    });
  });

  group('expandUserPath', () {
    test('expands ~ and makes paths absolute', () {
      expect(expandUserPath('~', home: '/h', cwd: '/c'), '/h');
      expect(expandUserPath('~/x', home: '/h', cwd: '/c'), '/h/x');
      expect(expandUserPath('x/../y', home: '/h', cwd: '/c'), '/c/y');
      expect(expandUserPath('  /abs/ ', home: '/h', cwd: '/c'), '/abs');
      expect(expandUserPath('', home: '/h', cwd: '/c'), '');
    });

    test('accepts file URIs pasted from a file manager', () {
      expect(expandUserPath('file:///tmp/a%20b', home: '/h', cwd: '/c'),
          '/tmp/a b');
    });
  });

  test('abbreviateHome shortens paths under the home directory', () {
    expect(abbreviateHome('/h/src', home: '/h'), '~/src');
    expect(abbreviateHome('/h', home: '/h'), '~');
    expect(abbreviateHome('/hx/src', home: '/h'), '/hx/src');
  });
}
