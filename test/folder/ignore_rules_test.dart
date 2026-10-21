import 'package:delta_view/compare/ignore_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shorthand: is [path] ignored by a `.gitignore` at the root with [text]?
bool ignored(String text, String path, {bool dir = false}) =>
    GitignoreChain.push(null, '', IgnoreRuleSet.parse(text))
        .isIgnored(path, isDirectory: dir);

void main() {
  group('gitignore patterns', () {
    test('skip blank lines, comments and trailing spaces', () {
      final rules = IgnoreRuleSet.parse('\n# a comment\n  \n*.log   \n');
      expect(rules.patterns.map((p) => p.toString()), ['*.log   ']);
      expect(ignored(r'\#hash', '#hash'), isTrue);
      expect(ignored(r'keep\ ', 'keep '), isTrue);
      expect(ignored('a.txt\r\n', 'a.txt'), isTrue, reason: 'CRLF files');
    });

    test('a name without a slash matches at any depth', () {
      expect(ignored('*.pyc', 'x.pyc'), isTrue);
      expect(ignored('*.pyc', 'a/b/x.pyc'), isTrue);
      expect(ignored('*.pyc', 'a/b/x.py'), isFalse);
      expect(ignored('build', 'src/build', dir: true), isTrue);
      expect(ignored('build', 'src/build'), isTrue);
    });

    test('* and ? never cross a slash', () {
      expect(ignored('doc/*.txt', 'doc/a.txt'), isTrue);
      expect(ignored('doc/*.txt', 'doc/x/a.txt'), isFalse);
      expect(ignored('a?c', 'abc'), isTrue);
      expect(ignored('a/?', 'a/b'), isTrue);
    });

    test('a leading or middle slash anchors to the folder', () {
      expect(ignored('/todo', 'todo'), isTrue);
      expect(ignored('/todo', 'src/todo'), isFalse);
      expect(ignored('src/gen', 'src/gen', dir: true), isTrue);
      expect(ignored('src/gen', 'lib/src/gen', dir: true), isFalse);
    });

    test('a trailing slash matches folders only', () {
      expect(ignored('out/', 'out', dir: true), isTrue);
      expect(ignored('out/', 'out'), isFalse);
      expect(ignored('out/', 'a/out', dir: true), isTrue);
    });

    test('** spans folders', () {
      expect(ignored('**/logs', 'logs', dir: true), isTrue);
      expect(ignored('**/logs', 'a/b/logs', dir: true), isTrue);
      expect(ignored('**/logs/debug.log', 'x/logs/debug.log'), isTrue);
      expect(ignored('a/**/b', 'a/b'), isTrue);
      expect(ignored('a/**/b', 'a/x/y/b'), isTrue);
      expect(ignored('a/**/b', 'c/a/x/b'), isFalse);
      expect(ignored('abc/**', 'abc/x'), isTrue);
      expect(ignored('abc/**', 'abc/x/y.txt'), isTrue);
      expect(ignored('abc/**', 'abc', dir: true), isFalse,
          reason: 'in git, only the contents match');
      expect(ignored('a**b', 'axxb'), isTrue);
      expect(ignored('a**b', 'ax/xb'), isFalse);
    });

    test('character classes', () {
      expect(ignored('*.[oa]', 'x.o'), isTrue);
      expect(ignored('*.[oa]', 'x.a'), isTrue);
      expect(ignored('*.[oa]', 'x.c'), isFalse);
      expect(ignored('file[0-9]', 'file7'), isTrue);
      expect(ignored('file[!0-9]', 'file7'), isFalse);
      expect(ignored('file[!0-9]', 'filex'), isTrue);
      expect(ignored('[]x]', ']'), isTrue);
      expect(ignored('a[', 'a['), isTrue, reason: 'unclosed [ is literal');
    });

    test('negation re-includes, last match wins', () {
      const text = '*.log\n!keep.log\n';
      expect(ignored(text, 'a.log'), isTrue);
      expect(ignored(text, 'keep.log'), isFalse);
      expect(ignored(r'\!bang', '!bang'), isTrue);
      expect(ignored('!keep.log\n*.log', 'keep.log'), isTrue);
    });

    test('regex characters in names are literal', () {
      expect(ignored('a+b(1).txt', 'a+b(1).txt'), isTrue);
      expect(ignored('a.txt', 'abtxt'), isFalse);
      expect(ignored(r'x$', r'x$'), isTrue);
    });
  });

  group('per-folder .gitignore files', () {
    final root = IgnoreRuleSet.parse('*.log\nbuild/\n');
    final sub = IgnoreRuleSet.parse('!important.log\n/local.txt\n');
    final chain = GitignoreChain.push(
        GitignoreChain.push(null, '', root), 'pkg', sub);

    test('rules apply to their folder and below', () {
      expect(chain.isIgnored('pkg/x.log', isDirectory: false), isTrue);
      expect(chain.isIgnored('pkg/deep/build', isDirectory: true), isTrue);
    });

    test('a deeper file overrides a shallower one', () {
      expect(chain.isIgnored('pkg/important.log', isDirectory: false), isFalse);
      expect(chain.isIgnored('pkg/a/important.log', isDirectory: false),
          isFalse);
    });

    test('anchored patterns are relative to their own folder', () {
      expect(chain.isIgnored('pkg/local.txt', isDirectory: false), isTrue);
      expect(chain.isIgnored('pkg/a/local.txt', isDirectory: false), isFalse);
    });

    test('a folder name prefix is not its parent', () {
      final c = GitignoreChain.push(
          null, 'pk', IgnoreRuleSet.parse('*.txt'));
      expect(c.isIgnored('pkg/a.txt', isDirectory: false), isFalse);
      expect(c.isIgnored('pk/a.txt', isDirectory: false), isTrue);
    });
  });

  group('user patterns', () {
    final rules =
        IgnoreRules(['node_modules', '*.pyc', 'build/**', '/docs/tmp']);

    test('plain names and globs match anywhere', () {
      expect(rules.isIgnored('a/node_modules', isDirectory: true), isTrue);
      expect(rules.isIgnored('x/y.pyc', isDirectory: false), isTrue);
    });

    test('path globs are anchored and take the folder itself', () {
      expect(rules.isIgnored('build', isDirectory: true), isTrue);
      expect(rules.isIgnored('build/a.o', isDirectory: false), isTrue);
      expect(rules.isIgnored('src/build', isDirectory: true), isFalse);
      expect(rules.isIgnored('docs/tmp', isDirectory: true), isTrue);
      expect(rules.isIgnored('x/docs/tmp', isDirectory: true), isFalse);
    });

    test('coversPath looks at every folder above', () {
      expect(rules.coversPath('a/node_modules/x/y.js'), isTrue);
      expect(rules.coversPath('src/main.dart'), isFalse);
    });

    test('case sensitivity follows the platform flag', () {
      expect(IgnoreRules(['*.PYC']).isIgnored('a.pyc', isDirectory: false),
          isFalse);
      expect(
          IgnoreRules(['*.PYC'], caseSensitive: false)
              .isIgnored('a.pyc', isDirectory: false),
          isTrue);
    });

    test('exactPattern matches one entry, whatever its name holds', () {
      for (final path in ['a/b[1]*.txt', 'x?', r'back\slash', 'sp ']) {
        final r = IgnoreRules([exactPattern(path)]);
        expect(r.isIgnored(path, isDirectory: false), isTrue, reason: path);
        expect(r.isIgnored('z/$path', isDirectory: false), isFalse);
      }
      expect(IgnoreRules([exactPattern('a*')]).isIgnored('ab',
          isDirectory: false), isFalse);
    });
  });
}
