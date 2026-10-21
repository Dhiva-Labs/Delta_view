import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:delta_view/compare/sources/archive_source.dart';
import 'package:delta_view/compare/sources/file_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The tree every fixture holds. Paths are deliberately messy: a leading
/// `./`, no explicit entries for most folders, and one explicit folder.
final _files = <String, String>{
  './README.md': '# Fixture\n',
  './src/main.dart': 'void main() {}\n',
  './src/util/strings.dart': 'String up(String s) => s.toUpperCase();\n',
  'docs/guide/intro.txt': 'Hello from the guide.\n',
};
const _explicitDir = 'empty/';

Archive _archive({DateTime? modified}) {
  final archive = Archive();
  final seconds =
      (modified ?? DateTime(2024, 5, 17, 10, 30)).millisecondsSinceEpoch ~/
          1000;
  for (final e in _files.entries) {
    archive.add(ArchiveFile.bytes(e.key, utf8.encode(e.value))
      ..lastModTime = seconds);
  }
  archive.add(ArchiveFile.directory(_explicitDir)..lastModTime = seconds);
  return archive;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('deltaview-archive-test-');
  });

  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  Future<String> fixture(String name, List<int> bytes) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  final tarBytes = TarEncoder().encodeBytes(_archive());
  final formats = <String, List<int> Function()>{
    'fixture.zip': () => ZipEncoder().encodeBytes(_archive()),
    'fixture.tar': () => tarBytes,
    'fixture.tar.gz': () => const GZipEncoder().encodeBytes(tarBytes),
    'fixture.tar.bz2': () => BZip2Encoder().encodeBytes(tarBytes),
    'fixture.tar.xz': () => XZEncoder().encodeBytes(tarBytes),
  };

  for (final format in formats.entries) {
    group(format.key, () {
      late String path;

      setUpAll(() async {
        path = await fixture(format.key, format.value());
      });

      test('indexes folders, including implicit ones', () async {
        final source = await FileSource.open(ArchiveSource(path));
        addTearDown(source.close);

        expect(source.writable, isFalse);
        final root = await source.list('');
        expect(
          {for (final e in root) e.name: e.isDirectory},
          {'README.md': false, 'src': true, 'docs': true, 'empty': true},
        );
        final src = await source.list('src');
        expect({for (final e in src) e.name: e.isDirectory},
            {'main.dart': false, 'util': true});
        expect(await source.list('empty'), isEmpty);
        expect((await source.list('docs/guide')).single.name, 'intro.txt');
      });

      test('reads entries and reports sizes and times', () async {
        final source = await FileSource.open(ArchiveSource(path));
        addTearDown(source.close);

        for (final e in _files.entries) {
          final relative = normalizeArchivePath(e.key);
          expect(utf8.decode(await source.read(relative)), e.value,
              reason: relative);
          final entry = (await source.stat(relative))!;
          expect(entry.isDirectory, isFalse);
          expect(entry.size, utf8.encode(e.value).length);
          expect(entry.modified, isNotNull);
          // zip keeps DOS time (two-second resolution); tar keeps seconds.
          expect(
              entry.modified!
                  .difference(DateTime(2024, 5, 17, 10, 30))
                  .inSeconds
                  .abs(),
              lessThanOrEqualTo(2));
        }
        expect(await source.stat('missing.txt'), isNull);
        expect((await source.stat(''))!.isDirectory, isTrue);
        expect((await source.stat('src'))!.isDirectory, isTrue);
      });

      test('roots at a folder inside the archive', () async {
        final source =
            await FileSource.open(ArchiveSource(path, innerPath: './src/'));
        addTearDown(source.close);

        final names = {for (final e in await source.list('')) e.name};
        expect(names, {'main.dart', 'util'});
        expect(utf8.decode(await source.read('util/strings.dart')),
            _files['./src/util/strings.dart']);
      });

      test('roots at a single file', () async {
        final source = await FileSource.open(
            ArchiveSource(path, innerPath: 'src/main.dart'));
        addTearDown(source.close);

        final entry = (await source.stat(''))!;
        expect(entry.isDirectory, isFalse);
        expect(entry.name, 'main.dart');
        expect(utf8.decode(await source.read('')), _files['./src/main.dart']);
        await expectLater(source.list(''), throwsA(isA<ArchiveSourceException>()));
      });

      test('refuses to change anything', () async {
        final source = await FileSource.open(ArchiveSource(path));
        addTearDown(source.close);

        await expectLater(source.write('new.txt', [1, 2, 3]),
            throwsA(isA<ArchiveSourceException>()));
        await expectLater(
            source.delete('README.md'), throwsA(isA<ArchiveSourceException>()));
        await expectLater(source.createDirectory('x'),
            throwsA(isA<ArchiveSourceException>()));
      });
    });
  }

  test('normalizes separators and dot segments', () {
    expect(normalizeArchivePath('./a/b/'), 'a/b');
    expect(normalizeArchivePath(r'a\b\c.txt'), 'a/b/c.txt');
    expect(normalizeArchivePath('/abs//x/./y'), 'abs/x/y');
    expect(normalizeArchivePath('../../etc/passwd'), 'etc/passwd');
    expect(normalizeArchivePath('a/../b'), 'b');
    expect(normalizeArchivePath('.'), '');
  });

  test('leaves symbolic links out and resolves hard links', () async {
    final out = OutputMemoryStream();
    final encoder = TarEncoder()..start(out);
    encoder.add(ArchiveFile.bytes('pkg/real.txt', utf8.encode('real')));
    // TarEncoder writes no hard links, so write that header by hand.
    (TarFile()
          ..filename = 'pkg/hard.txt'
          ..mode = 420
          ..typeFlag = TarFile.hardLink
          ..nameOfLinkedFile = 'pkg/real.txt')
        .write(out);
    encoder.add(ArchiveFile.symlink('pkg/soft.txt', 'real.txt'));
    encoder.finish();
    final path = await fixture(
        'links.tar.gz', const GZipEncoder().encodeBytes(out.getBytes()));
    final source = await FileSource.open(ArchiveSource(path));
    addTearDown(source.close);

    expect({for (final e in await source.list('pkg')) e.name},
        {'real.txt', 'hard.txt'});
    expect(utf8.decode(await source.read('pkg/hard.txt')), 'real');
    expect((await source.stat('pkg/hard.txt'))!.size, 4);
  });

  test('decompresses big tars to a scratch file, removed on close',
      () async {
    final scratch = Directory(p.join(tmp.path, 'scratch'));
    ArchiveFileSource.memoryBudget = 4096;
    ArchiveFileSource.scratchDirectory = scratch.path;
    addTearDown(() {
      ArchiveFileSource.memoryBudget = 64 * 1024 * 1024;
      ArchiveFileSource.scratchDirectory = null;
    });

    final archive = Archive();
    for (var i = 0; i < 2000; i++) {
      archive.add(
          ArchiveFile.bytes('d${i % 10}/f$i.txt', utf8.encode('file $i\n')));
    }
    final path = await fixture('many.tar.xz',
        XZEncoder().encodeBytes(TarEncoder().encodeBytes(archive)));
    final source = await FileSource.open(ArchiveSource(path));

    expect(scratch.listSync(), hasLength(1));
    // Every entry comes from the scratch file: reading them all must not
    // decompress the archive again each time.
    for (var i = 0; i < 2000; i++) {
      expect(
          utf8.decode(await source.read('d${i % 10}/f$i.txt')), 'file $i\n');
    }
    await source.close();
    expect(scratch.listSync(), isEmpty);
  });

  test('reads stored and bzip2-compressed zip entries', () async {
    final big = List.generate(200000, (i) => 'line $i').join('\n');
    final archive = Archive()
      ..add(ArchiveFile.bytes('stored.txt', utf8.encode('kept as is'))
        ..compression = CompressionType.none)
      ..add(ArchiveFile.bytes('bz.txt', utf8.encode('squeezed'))
        ..compression = CompressionType.bzip2)
      ..add(ArchiveFile.bytes('big.txt', utf8.encode(big)));
    final path =
        await fixture('methods.zip', ZipEncoder().encodeBytes(archive));
    final source = await FileSource.open(ArchiveSource(path));
    addTearDown(source.close);

    expect(utf8.decode(await source.read('stored.txt')), 'kept as is');
    expect(utf8.decode(await source.read('bz.txt')), 'squeezed');
    expect(utf8.decode(await source.read('big.txt')), big);
  });

  test('explains files that are not archives', () async {
    final text = await fixture('notes.txt', utf8.encode('just text'));
    await expectLater(
      FileSource.open(ArchiveSource(text)),
      throwsA(isA<ArchiveSourceException>().having(
          (e) => e.message, 'message', contains('not an archive'))),
    );

    final fakeGz = await fixture('broken.tar.gz', [0x1f, 0x8b, 1, 2, 3, 4]);
    await expectLater(
        FileSource.open(ArchiveSource(fakeGz)), throwsA(isA<ArchiveSourceException>()));

    final notTar = await fixture(
        'plain.gz', const GZipEncoder().encodeBytes(utf8.encode('x' * 2000)));
    await expectLater(
        FileSource.open(ArchiveSource(notTar)), throwsA(isA<ArchiveSourceException>()));

    await expectLater(
      FileSource.open(ArchiveSource(p.join(tmp.path, 'nope.zip'))),
      throwsA(isA<ArchiveSourceException>().having(
          (e) => e.message, 'message', contains('no longer exists'))),
    );
  });

  test('reindexes an archive that changed on disk', () async {
    ArchiveFileSource.keepRecentArchivesOpen = true;
    addTearDown(() => ArchiveFileSource.keepRecentArchivesOpen = false);

    Uint8List zipWith(String text) => ZipEncoder().encodeBytes(
        Archive()..add(ArchiveFile.bytes('a.txt', utf8.encode(text))));
    final path = await fixture('changing.zip', zipWith('one'));
    final first = await FileSource.open(ArchiveSource(path));
    expect(utf8.decode(await first.read('a.txt')), 'one');
    await first.close();

    await File(path).writeAsBytes(zipWith('two, longer'));
    final second = await FileSource.open(ArchiveSource(path));
    expect(utf8.decode(await second.read('a.txt')), 'two, longer');
    await second.close();
  });
}
