/// Recursive folder comparison. Runs in a background isolate so huge
/// trees never block the UI thread.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../diff/line_diff.dart';

enum EntryStatus { identical, modified, onlyLeft, onlyRight }

class CompareNode {
  CompareNode({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.status,
    this.leftSize,
    this.rightSize,
    this.leftModified,
    this.rightModified,
    this.addedLines,
    this.removedLines,
    List<CompareNode>? children,
  }) : children = children ?? [];

  final String name;
  final String relativePath;
  final bool isDirectory;
  EntryStatus status;
  final int? leftSize;
  final int? rightSize;
  final DateTime? leftModified;
  final DateTime? rightModified;

  /// Line-level stats for modified text files (null for binary, huge,
  /// or unmodified files): lines only in the right / only in the left.
  final int? addedLines;
  final int? removedLines;

  final List<CompareNode> children;

  int identicalCount = 0;
  int modifiedCount = 0;
  int onlyLeftCount = 0;
  int onlyRightCount = 0;

  int get changedCount => modifiedCount + onlyLeftCount + onlyRightCount;

  bool get hasChanges => !isDirectory
      ? status != EntryStatus.identical
      : changedCount > 0;

  bool get existsLeft => status != EntryStatus.onlyRight;
  bool get existsRight => status != EntryStatus.onlyLeft;
}

class CompareRequest {
  const CompareRequest(this.leftRoot, this.rightRoot, this.sendPort);

  final String leftRoot;
  final String rightRoot;
  final SendPort sendPort;
}

class CompareProgress {
  const CompareProgress(this.filesCompared, this.currentPath);

  final int filesCompared;
  final String currentPath;
}

/// Compares two folder trees. Reports [CompareProgress] through [onProgress]
/// and returns the merged root node.
Future<CompareNode> compareFolders(
  String leftRoot,
  String rightRoot, {
  void Function(CompareProgress progress)? onProgress,
}) async {
  final receivePort = ReceivePort();
  await Isolate.spawn(
    _compareEntry,
    CompareRequest(leftRoot, rightRoot, receivePort.sendPort),
  );

  await for (final message in receivePort) {
    if (message is CompareProgress) {
      onProgress?.call(message);
    } else if (message is CompareNode) {
      receivePort.close();
      return message;
    } else if (message is _CompareError) {
      receivePort.close();
      throw FileSystemException(message.message);
    }
  }
  throw StateError('Comparison isolate exited without a result');
}

class _CompareError {
  const _CompareError(this.message);

  final String message;
}

Future<void> _compareEntry(CompareRequest request) async {
  var count = 0;
  var lastReport = DateTime.now();
  try {
    final root = await _compareDir(
      request.leftRoot,
      request.rightRoot,
      '',
      (path) {
        count++;
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds > 80) {
          lastReport = now;
          request.sendPort.send(CompareProgress(count, path));
        }
      },
    );
    request.sendPort.send(root);
  } catch (e) {
    request.sendPort.send(_CompareError(e.toString()));
  }
}

Future<CompareNode> _compareDir(
  String leftDir,
  String rightDir,
  String relative,
  void Function(String path) tick,
) async {
  final leftEntries = await _listDir(leftDir);
  final rightEntries = await _listDir(rightDir);

  final names = <String>{...leftEntries.keys, ...rightEntries.keys}.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final leftStat = await _statOrNull(leftDir);
  final rightStat = await _statOrNull(rightDir);
  final node = CompareNode(
    name: relative.isEmpty ? p.basename(leftDir) : p.basename(relative),
    relativePath: relative,
    isDirectory: true,
    status: EntryStatus.identical,
    leftSize: leftStat?.size,
    rightSize: rightStat?.size,
    leftModified: leftStat?.modified,
    rightModified: rightStat?.modified,
  );

  for (final name in names) {
    final left = leftEntries[name];
    final right = rightEntries[name];
    final childRelative = relative.isEmpty ? name : p.join(relative, name);

    CompareNode child;
    if (left != null && right != null) {
      final leftIsDir = left is Directory;
      final rightIsDir = right is Directory;
      if (leftIsDir && rightIsDir) {
        child = await _compareDir(left.path, right.path, childRelative, tick);
      } else if (!leftIsDir && !rightIsDir) {
        child = await _compareFile(
            left as File, right as File, name, childRelative);
        tick(childRelative);
      } else {
        // One is a file, the other a directory — treat as modified.
        child = CompareNode(
          name: name,
          relativePath: childRelative,
          isDirectory: false,
          status: EntryStatus.modified,
        );
      }
    } else if (left != null) {
      child = await _oneSidedNode(left, name, childRelative,
          left: true, tick: tick);
    } else {
      child = await _oneSidedNode(right!, name, childRelative,
          left: false, tick: tick);
    }

    node.children.add(child);
    if (child.isDirectory) {
      node.identicalCount += child.identicalCount;
      node.modifiedCount += child.modifiedCount;
      node.onlyLeftCount += child.onlyLeftCount;
      node.onlyRightCount += child.onlyRightCount;
    } else {
      switch (child.status) {
        case EntryStatus.identical:
          node.identicalCount++;
        case EntryStatus.modified:
          node.modifiedCount++;
        case EntryStatus.onlyLeft:
          node.onlyLeftCount++;
        case EntryStatus.onlyRight:
          node.onlyRightCount++;
      }
    }
  }

  if (node.changedCount > 0) node.status = EntryStatus.modified;
  _sortDirsFirst(node.children);
  return node;
}

/// Meld-style ordering: directories first, then files, both A→Z.
void _sortDirsFirst(List<CompareNode> children) {
  children.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

Future<FileStat?> _statOrNull(String path) async {
  try {
    final stat = await FileStat.stat(path);
    return stat.type == FileSystemEntityType.notFound ? null : stat;
  } on FileSystemException {
    return null;
  }
}

Future<Map<String, FileSystemEntity>> _listDir(String dir) async {
  final result = <String, FileSystemEntity>{};
  try {
    await for (final entity in Directory(dir).list(followLinks: false)) {
      if (entity is Link) continue;
      result[p.basename(entity.path)] = entity;
    }
  } on FileSystemException {
    // Unreadable directory — treat as empty rather than aborting the scan.
  }
  return result;
}

Future<CompareNode> _compareFile(
  File left,
  File right,
  String name,
  String relative,
) async {
  int? leftSize, rightSize;
  DateTime? leftMod, rightMod;
  var status = EntryStatus.identical;
  try {
    final leftStat = await left.stat();
    final rightStat = await right.stat();
    leftSize = leftStat.size;
    rightSize = rightStat.size;
    leftMod = leftStat.modified;
    rightMod = rightStat.modified;
    if (leftStat.size != rightStat.size) {
      status = EntryStatus.modified;
    } else if (!await _sameContent(left, right)) {
      status = EntryStatus.modified;
    }
  } on FileSystemException {
    status = EntryStatus.modified;
  }

  (int, int)? lineStats;
  if (status == EntryStatus.modified) {
    lineStats = await _lineStats(left, right);
  }
  return CompareNode(
    name: name,
    relativePath: relative,
    isDirectory: false,
    status: status,
    leftSize: leftSize,
    rightSize: rightSize,
    leftModified: leftMod,
    rightModified: rightMod,
    addedLines: lineStats?.$1,
    removedLines: lineStats?.$2,
  );
}

/// Counts added/removed lines for a modified pair of text files, so the
/// tree can show "+a −r" without opening the diff. Returns null for
/// binary or oversized files.
Future<(int, int)?> _lineStats(File left, File right) async {
  const maxBytes = 2 * 1024 * 1024;
  try {
    if (await left.length() > maxBytes || await right.length() > maxBytes) {
      return null;
    }
    final leftBytes = await left.readAsBytes();
    final rightBytes = await right.readAsBytes();
    if (_looksBinary(leftBytes) || _looksBinary(rightBytes)) return null;
    final chunks = diffLines(
      splitLines(_decodeText(leftBytes)),
      splitLines(_decodeText(rightBytes)),
    );
    var added = 0, removed = 0;
    for (final chunk in chunks) {
      if (chunk.op == DiffOp.insert) added += chunk.lines.length;
      if (chunk.op == DiffOp.delete) removed += chunk.lines.length;
    }
    return (added, removed);
  } on FileSystemException {
    return null;
  }
}

bool _looksBinary(List<int> bytes) {
  final probe = bytes.length < 8192 ? bytes.length : 8192;
  for (var i = 0; i < probe; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

String _decodeText(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

Future<bool> _sameContent(File a, File b) async {
  const chunkSize = 128 * 1024;
  final ra = a.openSync();
  final rb = b.openSync();
  try {
    while (true) {
      final ba = ra.readSync(chunkSize);
      final bb = rb.readSync(chunkSize);
      if (ba.length != bb.length) return false;
      if (ba.isEmpty) return true;
      for (var i = 0; i < ba.length; i++) {
        if (ba[i] != bb[i]) return false;
      }
    }
  } finally {
    ra.closeSync();
    rb.closeSync();
  }
}

Future<CompareNode> _oneSidedNode(
  FileSystemEntity entity,
  String name,
  String relative, {
  required bool left,
  required void Function(String path) tick,
}) async {
  final status = left ? EntryStatus.onlyLeft : EntryStatus.onlyRight;
  if (entity is Directory) {
    final dirStat = await _statOrNull(entity.path);
    final node = CompareNode(
      name: name,
      relativePath: relative,
      isDirectory: true,
      status: status,
      leftSize: left ? dirStat?.size : null,
      rightSize: left ? null : dirStat?.size,
      leftModified: left ? dirStat?.modified : null,
      rightModified: left ? null : dirStat?.modified,
    );
    final children = await _listDir(entity.path);
    final names = children.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final childName in names) {
      final child = await _oneSidedNode(
        children[childName]!,
        childName,
        p.join(relative, childName),
        left: left,
        tick: tick,
      );
      node.children.add(child);
      if (child.isDirectory) {
        node.onlyLeftCount += child.onlyLeftCount;
        node.onlyRightCount += child.onlyRightCount;
      } else if (left) {
        node.onlyLeftCount++;
      } else {
        node.onlyRightCount++;
      }
    }
    _sortDirsFirst(node.children);
    return node;
  }

  tick(relative);
  int? size;
  DateTime? modified;
  try {
    final stat = await entity.stat();
    size = stat.size;
    modified = stat.modified;
  } on FileSystemException {
    // stat failed; leave metadata empty.
  }
  return CompareNode(
    name: name,
    relativePath: relative,
    isDirectory: false,
    status: status,
    leftSize: left ? size : null,
    rightSize: left ? null : size,
    leftModified: left ? modified : null,
    rightModified: left ? null : modified,
  );
}
