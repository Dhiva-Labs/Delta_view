/// Small JSON files in the app support directory, written atomically so a
/// crash mid-save never leaves a half-written file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The file named [name] in the app support directory.
Future<File> appSupportFile(String name) async =>
    File(p.join((await getApplicationSupportDirectory()).path, name));

/// The decoded content of [file]; null when it is missing or unreadable.
Future<Object?> readJsonFile(File file) async {
  try {
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString());
  } catch (e) {
    debugPrint('Could not read ${file.path}: $e');
    return null;
  }
}

/// Writes [json] to [file] through a temporary file and a rename.
Future<void> writeJsonFile(File file, Object json) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json),
      flush: true);
  await tmp.rename(file.path);
}
