import 'package:delta_view/ui/folder/entry_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitCommandLine', () {
    test('spaces separate words, quotes group them', () {
      expect(splitCommandLine('code --wait {file}'),
          ['code', '--wait', '{file}']);
      expect(splitCommandLine('"/opt/My Editor/edit" -n  {file} '),
          ['/opt/My Editor/edit', '-n', '{file}']);
      expect(splitCommandLine("vim -c 'set ft=diff' {file}"),
          ['vim', '-c', 'set ft=diff', '{file}']);
      expect(splitCommandLine(r'a\ b "c\"d"'), ['a b', 'c"d']);
      expect(splitCommandLine(''), isEmpty);
      expect(splitCommandLine('""'), ['']);
    });

    test('backslashes are path separators on Windows', () {
      expect(
          splitCommandLine(r'"C:\Program Files\Editor\ed.exe" {file}',
              windows: true),
          [r'C:\Program Files\Editor\ed.exe', '{file}']);
      expect(splitCommandLine(r'C:\tools\ed.exe', windows: true),
          [r'C:\tools\ed.exe']);
    });
  });

  group('editorCommand', () {
    const file = '/home/me/a file.txt';

    test('replaces {file} inside a word, without re-splitting the path', () {
      expect(editorCommand('code --goto {file}:1', file, os: 'linux'),
          ['code', '--goto', '$file:1']);
    });

    test('adds the path when the command has no placeholder', () {
      expect(editorCommand('gedit', file, os: 'linux'), ['gedit', file]);
    });

    test('falls back to the system opener', () {
      expect(editorCommand('  ', file, os: 'linux'), ['xdg-open', file]);
      expect(editorCommand('', file, os: 'macos'), ['open', file]);
      expect(editorCommand('', r'C:\a.txt', os: 'windows'),
          ['explorer', r'C:\a.txt']);
    });
  });

  test('fileManagerCommand per platform', () {
    expect(fileManagerCommand('/home/me/dir/a.txt', os: 'linux'),
        ['xdg-open', '/home/me/dir']);
    expect(fileManagerCommand('/Users/me/a.txt', os: 'macos'),
        ['open', '-R', '/Users/me/a.txt']);
    expect(fileManagerCommand(r'C:\me\a.txt', os: 'windows'),
        ['explorer', '/select,', r'C:\me\a.txt']);
  });
}
