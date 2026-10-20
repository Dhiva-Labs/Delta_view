/// Handing entries to the rest of the desktop: the file manager and the
/// user's editor.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The command that shows [path] in the platform's file manager: the
/// file selected on Windows and macOS, its folder opened on Linux (where
/// file managers have no common "select this file" option).
List<String> fileManagerCommand(String path, {String? os}) =>
    switch (os ?? Platform.operatingSystem) {
      'windows' => ['explorer', '/select,', path],
      'macos' => ['open', '-R', path],
      _ => ['xdg-open', p.dirname(path)],
    };

/// The command that opens [path] in the editor configured as [template]
/// (`{file}` is replaced with the path; without it the path is added at
/// the end), or in the system's default app when [template] is blank.
List<String> editorCommand(String template, String path, {String? os}) {
  final words = splitCommandLine(template,
      windows: (os ?? Platform.operatingSystem) == 'windows');
  if (words.isEmpty) {
    return switch (os ?? Platform.operatingSystem) {
      'windows' => ['explorer', path],
      'macos' => ['open', path],
      _ => ['xdg-open', path],
    };
  }
  final hasPlaceholder = words.any((w) => w.contains('{file}'));
  return [
    for (final w in words) w.replaceAll('{file}', path),
    if (!hasPlaceholder) path,
  ];
}

/// Splits a command line into words the way a shell would for simple
/// cases: spaces separate words, "double" and 'single' quotes group them.
/// Outside quotes a backslash escapes the next character, except on
/// Windows, where it is the path separator.
List<String> splitCommandLine(String command, {bool windows = false}) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' &&
          quote == '"' &&
          !windows &&
          i + 1 < command.length &&
          '"\\'.contains(command[i + 1])) {
        word.write(command[++i]);
      } else {
        word.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      inWord = true;
    } else if (c == r'\' && !windows && i + 1 < command.length) {
      word.write(command[++i]);
      inWord = true;
    } else if (c.trim().isEmpty) {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

/// Starts [command] without waiting for it or tying its lifetime to the
/// app. Throws [ProcessException] when the program cannot be started.
Future<void> launchDetached(List<String> command) async {
  await Process.start(
    command.first,
    command.sublist(1),
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
}
