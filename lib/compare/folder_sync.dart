/// Folder synchronization: which files to copy, overwrite or delete to
/// make one side match the other, worked out from a finished scan so the
/// user can review every step before anything changes, then carried out
/// through [FileSource].
library;

import 'dart:io';

import 'folder_compare.dart';
import 'sources/file_source.dart';

enum SyncMode {
  /// Make the right side an exact copy of the left: copy what is new or
  /// changed, delete what exists only on the right.
  mirrorLeftToRight,

  /// The same, right to left.
  mirrorRightToLeft,

  /// Copy what exists on one side only to the other; for files changed on
  /// both sides, the newer one wins. Nothing is deleted.
  twoWay,
}

enum SyncOpKind {
  /// A folder that is empty on the source side, created on the target.
  createFolder,

  /// A file new to the target.
  copy,

  /// A file replacing a different one on the target.
  overwrite,

  /// A file or a whole folder removed from the target.
  delete,
}

/// One step of a plan.
class SyncOp {
  const SyncOp(
    this.kind,
    this.path, {
    required this.target,
    this.isDirectory = false,
    this.bytes = 0,
    this.files = 1,
    this.modified,
  });

  final SyncOpKind kind;

  /// Relative path with `/` separators.
  final String path;

  /// The side that is written to or deleted from.
  final Side target;
  final bool isDirectory;

  /// Bytes written (copy, overwrite) or removed (delete).
  final int bytes;

  /// Files removed by a delete (everything inside a folder); 1 otherwise.
  final int files;

  /// The source file's modification time, kept on the copy where the
  /// target allows it.
  final DateTime? modified;

  Side get source => target.other;

  bool get destructive =>
      kind == SyncOpKind.overwrite || kind == SyncOpKind.delete;
}

/// An entry a two-way sync leaves alone, with the reason.
class SyncSkip {
  const SyncSkip(this.path, this.reason);

  final String path;
  final String reason;
}

class SyncPlan {
  SyncPlan(List<SyncOp> ops, {this.skipped = const []})
      // Deletes first, so a file can replace a folder of the same name (and
      // the other way round); then folders, then files, each in tree order.
      : ops = [
          ...ops.where((o) => o.kind == SyncOpKind.delete),
          ...ops.where((o) => o.kind == SyncOpKind.createFolder),
          ...ops.where((o) =>
              o.kind == SyncOpKind.copy || o.kind == SyncOpKind.overwrite),
        ];

  final List<SyncOp> ops;
  final List<SyncSkip> skipped;

  bool get isEmpty => ops.isEmpty;

  /// Overwrites or deletes something: needs the user's explicit go-ahead.
  bool get destructive => ops.any((o) => o.destructive);

  int count(SyncOpKind kind) => ops.where((o) => o.kind == kind).length;

  /// Files and folders created on the target.
  int get copyCount =>
      count(SyncOpKind.copy) + count(SyncOpKind.createFolder);
  int get overwriteCount => count(SyncOpKind.overwrite);
  int get deleteCount => count(SyncOpKind.delete);

  /// Files removed, counting everything inside deleted folders.
  int get deletedFiles => ops
      .where((o) => o.kind == SyncOpKind.delete)
      .fold(0, (sum, o) => sum + o.files);

  int bytesFor(SyncOpKind kind) =>
      ops.where((o) => o.kind == kind).fold(0, (sum, o) => sum + o.bytes);

  /// Bytes written by copies and overwrites.
  int get bytesToWrite =>
      bytesFor(SyncOpKind.copy) + bytesFor(SyncOpKind.overwrite);

  /// The sides this plan changes.
  Set<Side> get targets => {for (final o in ops) o.target};
}

/// Plans [mode] over [root], or over just the [only] entries (a selection)
/// when given.
SyncPlan planSync(CompareNode root, SyncMode mode,
    {Iterable<CompareNode>? only}) {
  final planner = _Planner();
  final nodes = only == null ? [root] : topmost(only);
  for (final node in nodes) {
    switch (mode) {
      case SyncMode.mirrorLeftToRight:
        planner.mirror(node, Side.left);
      case SyncMode.mirrorRightToLeft:
        planner.mirror(node, Side.right);
      case SyncMode.twoWay:
        planner.twoWay(node);
    }
  }
  return SyncPlan(planner.ops, skipped: planner.skipped);
}

/// Copies [nodes] from the [from] side to the other: new and changed
/// files only. Entries missing on the source are left alone.
SyncPlan planCopy(Iterable<CompareNode> nodes, {required Side from}) {
  final planner = _Planner();
  for (final node in topmost(nodes)) {
    planner.copy(node, from);
  }
  return SyncPlan(planner.ops);
}

/// Deletes [nodes] on [side].
SyncPlan planDelete(Iterable<CompareNode> nodes, {required Side side}) {
  final planner = _Planner();
  for (final node in topmost(nodes)) {
    if (node.relativePath.isEmpty) continue; // never the root itself
    planner.delete(node, side);
  }
  return SyncPlan(planner.ops);
}

/// [nodes] without those inside another one of them, so a folder and a
/// file in it are not handled twice.
List<CompareNode> topmost(Iterable<CompareNode> nodes) {
  final list = nodes.toList();
  final paths = {for (final n in list) n.relativePath};
  if (paths.contains('')) {
    return [list.firstWhere((n) => n.relativePath.isEmpty)];
  }
  bool covered(String path) {
    var i = path.lastIndexOf('/');
    while (i > 0) {
      if (paths.contains(path.substring(0, i))) return true;
      i = path.lastIndexOf('/', i - 1);
    }
    return false;
  }

  final seen = <String>{};
  return [
    for (final n in list)
      if (!covered(n.relativePath) && seen.add(n.relativePath)) n,
  ];
}

class _Planner {
  final ops = <SyncOp>[];
  final skipped = <SyncSkip>[];

  void mirror(CompareNode node, Side from) {
    final to = from.other;
    if (node.isTypeConflict) {
      _replace(node, from);
    } else if (!node.existsOn(from)) {
      delete(node, to);
    } else if (!node.existsOn(to)) {
      _copyAll(node, from);
    } else if (node.isDirectory) {
      for (final child in node.children) {
        mirror(child, from);
      }
    } else if (node.status == EntryStatus.modified) {
      _file(SyncOpKind.overwrite, node, from);
    }
  }

  void copy(CompareNode node, Side from) {
    final to = from.other;
    if (!node.existsOn(from)) return;
    if (node.isTypeConflict) {
      _replace(node, from);
    } else if (!node.existsOn(to)) {
      _copyAll(node, from);
    } else if (node.isDirectory) {
      for (final child in node.children) {
        copy(child, from);
      }
    } else if (node.status == EntryStatus.modified) {
      _file(SyncOpKind.overwrite, node, from);
    }
  }

  void twoWay(CompareNode node) {
    if (node.isTypeConflict) {
      skipped.add(SyncSkip(node.relativePath,
          'A file on one side and a folder on the other'));
    } else if (!node.existsLeft) {
      _copyAll(node, Side.right);
    } else if (!node.existsRight) {
      _copyAll(node, Side.left);
    } else if (node.isDirectory) {
      for (final child in node.children) {
        twoWay(child);
      }
    } else if (node.status == EntryStatus.modified) {
      final l = node.leftModified, r = node.rightModified;
      if (l == null || r == null) {
        skipped.add(SyncSkip(node.relativePath, 'Modification time unknown'));
      } else if (l.difference(r).abs() < quickCompareTolerance) {
        skipped.add(SyncSkip(
            node.relativePath, 'Both sides have the same modification time'));
      } else {
        final newer = l.isAfter(r) ? Side.left : Side.right;
        _file(SyncOpKind.overwrite, node, newer);
      }
    }
  }

  void delete(CompareNode node, Side side) {
    if (!node.existsOn(side)) return;
    final isDirectory = node.isDirectoryOn(side);
    ops.add(SyncOp(
      SyncOpKind.delete,
      node.relativePath,
      target: side,
      isDirectory: isDirectory,
      bytes: node.sizeOn(side) ?? 0,
      files: isDirectory ? _filesOn(node, side) : 1,
    ));
  }

  /// A file on one side and a folder on the other: the target's entry
  /// goes, then the source's is copied in.
  void _replace(CompareNode node, Side from) {
    delete(node, from.other);
    if (node.folderSide == from) {
      _copyChildren(node, from);
      if (!node.children.any((c) => c.existsOn(from))) _folder(node, from);
    } else {
      _file(SyncOpKind.copy, node, from);
    }
  }

  /// Copies an entry that does not exist on the target at all.
  void _copyAll(CompareNode node, Side from) {
    if (!node.isDirectory) {
      _file(SyncOpKind.copy, node, from);
      return;
    }
    if (!node.children.any((c) => c.existsOn(from))) {
      _folder(node, from);
    } else {
      _copyChildren(node, from);
    }
  }

  void _copyChildren(CompareNode node, Side from) {
    for (final child in node.children) {
      if (child.existsOn(from)) _copyAll(child, from);
    }
  }

  void _folder(CompareNode node, Side from) => ops.add(SyncOp(
        SyncOpKind.createFolder,
        node.relativePath,
        target: from.other,
        isDirectory: true,
        files: 0,
      ));

  void _file(SyncOpKind kind, CompareNode node, Side from) => ops.add(SyncOp(
        kind,
        node.relativePath,
        target: from.other,
        bytes: node.sizeOn(from) ?? 0,
        modified: node.modifiedOn(from),
      ));

  static int _filesOn(CompareNode node, Side side) {
    var n = 0;
    for (final child in node.children) {
      if (!child.existsOn(side)) continue;
      n += child.isDirectoryOn(side) ? _filesOn(child, side) : 1;
    }
    return n;
  }
}

class SyncProgress {
  const SyncProgress({
    required this.done,
    required this.total,
    required this.bytesDone,
    required this.totalBytes,
    required this.currentPath,
  });

  final int done;
  final int total;
  final int bytesDone;
  final int totalBytes;
  final String currentPath;

  double get fraction => totalBytes > 0
      ? bytesDone / totalBytes
      : total == 0
          ? 1
          : done / total;
}

class SyncError {
  const SyncError(this.op, this.message);

  final SyncOp op;
  final String message;
}

/// Carries out [plan]. A failed step is recorded and the rest still run.
/// [isCancelled] is checked between steps.
Future<List<SyncError>> runSyncPlan(
  SyncPlan plan, {
  required FileSource left,
  required FileSource right,
  void Function(SyncProgress progress)? onProgress,
  bool Function()? isCancelled,
}) async {
  FileSource sourceFor(Side side) => side == Side.left ? left : right;
  final errors = <SyncError>[];
  final totalBytes = plan.bytesToWrite;
  var bytesDone = 0;
  for (var i = 0; i < plan.ops.length; i++) {
    if (isCancelled?.call() ?? false) break;
    final op = plan.ops[i];
    onProgress?.call(SyncProgress(
      done: i,
      total: plan.ops.length,
      bytesDone: bytesDone,
      totalBytes: totalBytes,
      currentPath: op.path,
    ));
    final target = sourceFor(op.target);
    try {
      if (!target.writable) {
        throw UnsupportedError('The ${op.target.name} side is read-only.');
      }
      switch (op.kind) {
        case SyncOpKind.delete:
          await target.delete(op.path);
        case SyncOpKind.createFolder:
          await target.createDirectory(op.path);
        case SyncOpKind.copy:
        case SyncOpKind.overwrite:
          final bytes = await sourceFor(op.source).read(op.path);
          await target.write(op.path, bytes);
          await _keepModified(target, op);
          bytesDone += op.bytes;
      }
    } catch (e) {
      errors.add(SyncError(op, _message(e)));
    }
  }
  onProgress?.call(SyncProgress(
    done: plan.ops.length,
    total: plan.ops.length,
    bytesDone: totalBytes,
    totalBytes: totalBytes,
    currentPath: '',
  ));
  return errors;
}

/// Gives a copy its source's modification time when the target is on this
/// machine, so a quick (size and date) compare sees the two as identical
/// and a two-way sync does not mistake the copy for a newer edit.
/// [FileSource] has no way to set it on other kinds of target.
Future<void> _keepModified(FileSource target, SyncOp op) async {
  final modified = op.modified;
  final path = target.localPath(op.path);
  if (modified == null || path == null) return;
  try {
    await File(path).setLastModified(modified);
  } on FileSystemException {
    // Some file systems refuse; the copy itself succeeded.
  }
}

String _message(Object error) => switch (error) {
      FileSystemException e => e.osError?.message.isNotEmpty == true
          ? e.osError!.message
          : e.message,
      UnsupportedError e => e.message ?? '$e',
      _ => '$error',
    };
