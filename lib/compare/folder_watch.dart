/// Watches the local folders of a comparison so the view can rescan when
/// something changes on disk.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One side to watch: its root on this machine and the folders inside it
/// that the last scan saw (relative, `/`-separated, shallow ones first).
class WatchRoot {
  const WatchRoot(this.path, this.folders);

  final String path;
  final List<String> folders;
}

/// Calls [onChange] once changes settle for [debounce].
///
/// Linux has no recursive watch (`Directory.watch(recursive: true)` is
/// unsupported there), so each folder gets its own watch, up to
/// [maxFolders] in all; shallow folders are watched first because that is
/// where people usually work. Other platforms watch each root
/// recursively and drop events from folders the scan did not include
/// (ignored ones such as `node_modules`).
class FolderWatcher {
  FolderWatcher({
    required this.onChange,
    this.debounce = const Duration(milliseconds: 700),
    this.maxFolders = 2000,
    this.isIgnored,
  });

  final void Function() onChange;
  final Duration debounce;
  final int maxFolders;

  /// Paths (relative to a root) whose changes do not matter.
  final bool Function(String relative)? isIgnored;

  final _subscriptions = <StreamSubscription<FileSystemEvent>>[];
  Timer? _timer;
  var _watched = 0;
  var _capped = false;

  /// Folders being watched (roots count as one each where the watch is
  /// recursive).
  int get watchedCount => _watched;

  /// True when some folders went unwatched because of [maxFolders].
  bool get capped => _capped;

  /// Replaces whatever was watched before with [roots].
  void watch(List<WatchRoot> roots) {
    _stopWatching();
    final recursive = !Platform.isLinux;
    var budget = maxFolders;
    for (final root in roots) {
      final known = {'', ...root.folders};
      if (recursive) {
        _add(root, root.path, known, recursive: true);
        continue;
      }
      for (final folder in ['', ...root.folders]) {
        if (budget <= 0) {
          _capped = true;
          break;
        }
        budget--;
        _add(
            root,
            folder.isEmpty
                ? root.path
                : p.joinAll([root.path, ...folder.split('/')]),
            known,
            recursive: false);
      }
    }
  }

  void _add(WatchRoot root, String dir, Set<String> known,
      {required bool recursive}) {
    try {
      _subscriptions.add(Directory(dir)
          .watch(recursive: recursive)
          .listen((event) => _onEvent(root, known, event),
              onError: (Object _) {}, cancelOnError: false));
      _watched++;
    } on FileSystemException {
      // Gone since the scan, or not watchable; the next rescan catches up.
    }
  }

  void _onEvent(WatchRoot root, Set<String> known, FileSystemEvent event) {
    final relative = p.relative(event.path, from: root.path);
    if (relative.startsWith('..')) return;
    final path = p.split(relative).where((s) => s != '.').join('/');
    final parent = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    // Changes inside folders the scan left out (ignored ones) or did not
    // reach do not change the comparison.
    if (!known.contains(parent) && !known.contains(path)) return;
    if (path.isNotEmpty && (isIgnored?.call(path) ?? false)) return;
    _timer?.cancel();
    _timer = Timer(debounce, onChange);
  }

  void _stopWatching() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _watched = 0;
    _capped = false;
  }

  void dispose() {
    _timer?.cancel();
    _stopWatching();
  }
}
