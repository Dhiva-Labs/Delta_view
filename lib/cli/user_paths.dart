/// Turning what a user typed (on the command line or in a path field)
/// into a path the app can open.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

enum PathKind { directory, file, missing }

/// Expands a leading `~` and makes [input] absolute against [cwd]. Returns
/// the empty string for blank input. [home] and [cwd] default to the real
/// ones; tests pass their own.
String expandUserPath(String input, {String? home, String? cwd}) {
  var path = input.trim();
  if (path.isEmpty) return '';
  // A pasted file URI (from a file manager) is a path too.
  if (path.startsWith('file://')) {
    path = Uri.parse(path).toFilePath();
  }
  if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
    final h = home ?? userHomeDirectory();
    if (h != null) path = h + path.substring(1);
  }
  if (!p.isAbsolute(path)) {
    path = p.join(cwd ?? Directory.current.path, path);
  }
  return p.normalize(path);
}

String? userHomeDirectory() {
  final env = Platform.environment;
  return env['HOME'] ?? env['USERPROFILE'];
}

/// What is at [path] right now. Symbolic links are followed, so a link to
/// a folder counts as a folder.
PathKind pathKindOf(String path) {
  if (path.isEmpty) return PathKind.missing;
  return switch (FileSystemEntity.typeSync(path)) {
    FileSystemEntityType.directory => PathKind.directory,
    FileSystemEntityType.file => PathKind.file,
    _ => PathKind.missing,
  };
}

/// A shorter form for display: the home directory becomes `~`.
String abbreviateHome(String path, {String? home}) {
  final h = home ?? userHomeDirectory();
  if (h == null || h.isEmpty) return path;
  if (path == h) return '~';
  if (path.startsWith('$h/') || path.startsWith('$h\\')) {
    return '~${path.substring(h.length)}';
  }
  return path;
}
