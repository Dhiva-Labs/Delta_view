import 'dart:async';
import 'dart:io';

import 'package:delta_view/compare/folder_watch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('delta_view_watch');
    Directory(p.join(root.path, 'sub', 'deep')).createSync(recursive: true);
    Directory(p.join(root.path, 'node_modules')).createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<int> changesAfter(FolderWatcher Function(void Function()) make,
      void Function() edit) async {
    var calls = 0;
    final done = Completer<void>();
    final watcher = make(() {
      calls++;
      if (!done.isCompleted) done.complete();
    });
    watcher.watch([
      WatchRoot(root.path, const ['sub', 'sub/deep'])
    ]);
    // Let the watches settle before changing anything.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    edit();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    watcher.dispose();
    return calls;
  }

  test('a change in a nested folder fires once after the debounce', () async {
    final calls = await changesAfter(
      (onChange) => FolderWatcher(
          onChange: onChange, debounce: const Duration(milliseconds: 50)),
      () {
        File(p.join(root.path, 'sub', 'deep', 'a.txt')).writeAsStringSync('a');
        File(p.join(root.path, 'sub', 'deep', 'b.txt')).writeAsStringSync('b');
      },
    );
    expect(calls, 1);
  });

  test('changes in folders the scan left out are ignored', () async {
    final calls = await changesAfter(
      (onChange) => FolderWatcher(
        onChange: onChange,
        debounce: const Duration(milliseconds: 50),
        isIgnored: (path) => path.startsWith('node_modules'),
      ),
      () => File(p.join(root.path, 'node_modules', 'x.js'))
          .writeAsStringSync('x'),
    );
    expect(calls, 0);
  });

  test('the number of watched folders is capped', () {
    final watcher = FolderWatcher(onChange: () {}, maxFolders: 2);
    watcher.watch([
      WatchRoot(root.path, const ['sub', 'sub/deep'])
    ]);
    if (Platform.isLinux) {
      expect(watcher.watchedCount, 2);
      expect(watcher.capped, isTrue);
    } else {
      expect(watcher.watchedCount, 1, reason: 'one recursive watch');
    }
    watcher.dispose();
  });
}
