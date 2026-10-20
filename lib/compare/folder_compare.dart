/// Recursive folder comparison over any two [SourceSpec]s.
///
/// [FolderScan] runs the scan in a background isolate that opens its own
/// [FileSource]s from the (plain data) specs, so huge trees and slow
/// servers never block the UI thread, and a scan can be stopped at once by
/// killing the isolate. [FolderScanner] is the scan itself, usable in any
/// isolate (the tests drive it directly with in-memory sources).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diff/compare_options.dart';
import '../diff/line_diff.dart';
import 'folder_format.dart';
import 'ignore_rules.dart';
import 'sources/file_source.dart';

enum EntryStatus { identical, modified, onlyLeft, onlyRight }

enum Side {
  left,
  right;

  Side get other => this == left ? right : left;
}

class CompareNode {
  CompareNode({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.status,
    this.folderSide,
    this.leftSize,
    this.rightSize,
    this.leftModified,
    this.rightModified,
    this.addedLines,
    this.removedLines,
    List<CompareNode>? children,
  }) : children = children ?? [];

  final String name;

  /// Path from the comparison root with `/` separators; empty for the root.
  final String relativePath;
  final bool isDirectory;
  EntryStatus status;

  /// Set when the entry is a file on one side and a folder on the other.
  /// The node then shows as a modified file, and [children] hold the
  /// folder side's contents so a sync can copy it across.
  final Side? folderSide;

  /// For folders, the total size of the files inside on that side.
  int? leftSize;
  int? rightSize;
  final DateTime? leftModified;
  final DateTime? rightModified;

  /// Line-level stats for modified text files (null for binary, huge,
  /// or unmodified files): lines only in the right / only in the left.
  final int? addedLines;
  final int? removedLines;

  final List<CompareNode> children;

  /// Entries below a folder by status. Files count, and so do empty
  /// folders, so a new empty folder still shows up as a change.
  int identicalCount = 0;
  int modifiedCount = 0;
  int onlyLeftCount = 0;
  int onlyRightCount = 0;

  int get changedCount => modifiedCount + onlyLeftCount + onlyRightCount;

  bool get isTypeConflict => folderSide != null;

  bool get hasChanges => !isDirectory
      ? status != EntryStatus.identical
      : status != EntryStatus.identical || changedCount > 0;

  bool get existsLeft => status != EntryStatus.onlyRight;
  bool get existsRight => status != EntryStatus.onlyLeft;
  bool existsOn(Side side) => side == Side.left ? existsLeft : existsRight;

  /// Whether the entry is a folder on [side] (false where it is missing).
  bool isDirectoryOn(Side side) => !existsOn(side)
      ? false
      : isTypeConflict
          ? folderSide == side
          : isDirectory;

  int? sizeOn(Side side) => side == Side.left ? leftSize : rightSize;
  DateTime? modifiedOn(Side side) =>
      side == Side.left ? leftModified : rightModified;

  /// Counts this node as a leaf into a parent folder's totals.
  void _countInto(CompareNode parent) {
    switch (status) {
      case EntryStatus.identical:
        parent.identicalCount++;
      case EntryStatus.modified:
        parent.modifiedCount++;
      case EntryStatus.onlyLeft:
        parent.onlyLeftCount++;
      case EntryStatus.onlyRight:
        parent.onlyRightCount++;
    }
  }
}

/// What the scan should compare and leave out.
class ScanOptions {
  const ScanOptions({
    this.ignorePatterns = const [],
    this.respectGitignore = true,
    this.quick = false,
    this.compareOptions = CompareOptions.exact,
    this.caseSensitiveIgnore = true,
  });

  /// The user's patterns (settings plus any added for this comparison).
  final List<String> ignorePatterns;

  /// Read `.gitignore` files on both sides and leave out what they ignore.
  final bool respectGitignore;

  /// Size and modification time decide, nothing is read. Much faster on
  /// huge trees and slow servers.
  final bool quick;

  /// With a full compare, text files that differ only in ways these rules
  /// ignore count as identical.
  final CompareOptions compareOptions;

  /// Patterns match names case-sensitively (false on Windows and macOS,
  /// whose file systems usually ignore case).
  final bool caseSensitiveIgnore;
}

class ScanProgress {
  const ScanProgress(this.filesCompared, this.currentPath);

  final int filesCompared;
  final String currentPath;
}

/// A folder that could not be listed or a file that could not be read.
/// The scan carries on; the entry shows what was known about it.
class ScanIssue {
  const ScanIssue(this.path, this.message);

  final String path;
  final String message;
}

class ScanResult {
  const ScanResult({
    required this.root,
    required this.options,
    required this.elapsed,
    this.ignoredCount = 0,
    this.ignoredPaths = const [],
    this.issues = const [],
    this.leftWritable = false,
    this.rightWritable = false,
    this.leftLocal = false,
    this.rightLocal = false,
  });

  final CompareNode root;
  final ScanOptions options;
  final Duration elapsed;

  /// Entries left out by ignore rules. Their contents were never read, so
  /// an ignored folder counts once.
  final int ignoredCount;

  /// The first few ignored paths, for showing what was left out.
  final List<String> ignoredPaths;
  final List<ScanIssue> issues;

  /// [FileSource.writable] of each side.
  final bool leftWritable;
  final bool rightWritable;

  /// Whether each side has paths on this machine ([FileSource.localPath]).
  final bool leftLocal;
  final bool rightLocal;

  bool writable(Side side) => side == Side.left ? leftWritable : rightWritable;
  bool isLocal(Side side) => side == Side.left ? leftLocal : rightLocal;
}

/// Why a scan could not run. [unsupported] marks a kind of source this
/// build cannot open yet, which the view shows as a notice, not a fault.
class ScanFailure implements Exception {
  const ScanFailure(this.message, {this.unsupported = false});

  final String message;
  final bool unsupported;

  @override
  String toString() => message;
}

/// The scan was stopped with [FolderScan.cancel].
class ScanCancelled implements Exception {
  const ScanCancelled();

  @override
  String toString() => 'Scan cancelled';
}

/// A folder comparison running in its own isolate.
class FolderScan {
  FolderScan._(this._onProgress) {
    // Callers that stop listening (a closed tab) must not leave an
    // unhandled cancellation behind.
    _completer.future.ignore();
  }

  /// Starts comparing [left] with [right]. Progress arrives through
  /// [onProgress] about every 80 ms.
  static FolderScan start(
    SourceSpec left,
    SourceSpec right, {
    ScanOptions options = const ScanOptions(),
    void Function(ScanProgress progress)? onProgress,
  }) {
    final scan = FolderScan._(onProgress);
    scan._spawn(_ScanRequest(left, right, options, scan._port.sendPort));
    return scan;
  }

  final void Function(ScanProgress progress)? _onProgress;
  final _completer = Completer<ScanResult>();
  final _port = ReceivePort('folder scan');
  Isolate? _isolate;

  /// Completes with the result, or fails with [ScanFailure] or
  /// [ScanCancelled].
  Future<ScanResult> get result => _completer.future;

  bool get isRunning => !_completer.isCompleted;

  Future<void> _spawn(_ScanRequest request) async {
    _port.listen(_onMessage);
    try {
      final isolate = await Isolate.spawn(
        _scanMain,
        request,
        onExit: _port.sendPort,
        onError: _port.sendPort,
        debugName: 'folder scan',
      );
      if (_completer.isCompleted) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } catch (e) {
      _finish(error: ScanFailure('$e'));
    }
  }

  void _onMessage(Object? message) {
    switch (message) {
      case ScanProgress progress:
        if (isRunning) _onProgress?.call(progress);
      case ScanResult result:
        _finish(result: result);
      case ScanFailure failure:
        _finish(error: failure);
      case [final error, _]:
        // Uncaught error inside the isolate (onError sends [error, stack]).
        _finish(error: ScanFailure('$error'));
      case null:
        // The isolate exited; anything still pending failed silently.
        _finish(error: const ScanFailure('The scan stopped unexpectedly.'));
    }
  }

  void _finish({ScanResult? result, Object? error}) {
    if (_completer.isCompleted) return;
    if (result != null) {
      _completer.complete(result);
    } else {
      _completer.completeError(error!);
    }
    _port.close();
  }

  /// Stops the scan now. [result] fails with [ScanCancelled].
  void cancel() {
    if (_completer.isCompleted) return;
    _isolate?.kill(priority: Isolate.immediate);
    _finish(error: const ScanCancelled());
  }
}

/// Compares two folder trees in a background isolate and returns the
/// merged tree.
Future<ScanResult> compareFolders(
  SourceSpec left,
  SourceSpec right, {
  ScanOptions options = const ScanOptions(),
  void Function(ScanProgress progress)? onProgress,
}) =>
    FolderScan.start(left, right, options: options, onProgress: onProgress)
        .result;

class _ScanRequest {
  const _ScanRequest(this.left, this.right, this.options, this.port);

  final SourceSpec left;
  final SourceSpec right;
  final ScanOptions options;
  final SendPort port;
}

Future<void> _scanMain(_ScanRequest request) async {
  FileSource? left, right;
  try {
    left = await FileSource.open(request.left);
    right = await FileSource.open(request.right);
    final result = await FolderScanner(
      left,
      right,
      options: request.options,
      onProgress: request.port.send,
    ).run();
    await _closeQuietly(left);
    await _closeQuietly(right);
    // Hands the tree over without copying it, however big it is.
    Isolate.exit(request.port, result);
  } catch (e) {
    await _closeQuietly(left);
    await _closeQuietly(right);
    request.port.send(_failureFor(e));
  }
}

Future<void> _closeQuietly(FileSource? source) async {
  try {
    await source?.close();
  } catch (_) {}
}

ScanFailure _failureFor(Object error) => switch (error) {
      ScanFailure f => f,
      UnsupportedError e =>
        ScanFailure(e.message ?? 'This kind of folder is not supported yet.',
            unsupported: true),
      FileSystemException e => ScanFailure(
          e.path == null ? e.message : '${e.message}: ${e.path}'),
      _ => ScanFailure('$error'),
    };

/// Files up to this size get a line count (+added −removed) when modified.
const _statsMaxBytes = 2 * 1024 * 1024;

/// Files up to this size are compared by the text rules when their bytes
/// differ. Bigger ones are reported as modified.
const _textMaxBytes = 8 * 1024 * 1024;

/// Modification times closer than this count as equal in a quick compare:
/// FAT, zip files and many copy tools round to two seconds.
const quickCompareTolerance = Duration(seconds: 2);

/// The scan itself, over two open sources.
class FolderScanner {
  FolderScanner(
    this.left,
    this.right, {
    this.options = const ScanOptions(),
    this.onProgress,
  }) : _rules = IgnoreRules(options.ignorePatterns,
            caseSensitive: options.caseSensitiveIgnore);

  final FileSource left;
  final FileSource right;
  final ScanOptions options;
  final void Function(ScanProgress progress)? onProgress;

  final IgnoreRules _rules;
  final _stopwatch = Stopwatch();
  final _issues = <ScanIssue>[];
  final _ignoredPaths = <String>[];
  var _ignoredCount = 0;
  var _files = 0;
  var _lastReport = Duration.zero;

  /// Both sides are on this machine: folders are walked one at a time with
  /// synchronous calls, the fastest way through a local disk. Otherwise
  /// several folders and files are fetched at once, which hides network
  /// latency.
  late final bool _bothLocal;
  final _gate = _Gate(6);

  static const _maxIgnoredPaths = 500;
  static const _maxIssues = 500;

  Future<ScanResult> run() async {
    _stopwatch.start();
    final leftRoot = await _requireFolder(left, 'left');
    final rightRoot = await _requireFolder(right, 'right');
    _bothLocal = left.localPath('') != null && right.localPath('') != null;

    final root = await _compareFolder(
      '',
      left.spec.label,
      leftEntry: leftRoot,
      rightEntry: rightRoot,
      leftChain: null,
      rightChain: null,
    );
    return ScanResult(
      root: root,
      options: options,
      elapsed: _stopwatch.elapsed,
      ignoredCount: _ignoredCount,
      ignoredPaths: _ignoredPaths,
      issues: _issues,
      leftWritable: left.writable,
      rightWritable: right.writable,
      leftLocal: left.localPath('') != null,
      rightLocal: right.localPath('') != null,
    );
  }

  Future<SourceEntry> _requireFolder(FileSource source, String side) async {
    final entry = await source.stat('');
    if (entry == null) {
      throw ScanFailure(
          'The $side folder does not exist: ${source.spec.description}');
    }
    if (!entry.isDirectory) {
      throw ScanFailure(
          'The $side side is a file, not a folder: ${source.spec.description}');
    }
    return entry;
  }

  void _tick(String path) {
    _files++;
    final now = _stopwatch.elapsed;
    if (now - _lastReport > const Duration(milliseconds: 80)) {
      _lastReport = now;
      onProgress?.call(ScanProgress(_files, path));
    }
  }

  void _issue(String path, Object error) {
    if (_issues.length < _maxIssues) {
      _issues.add(ScanIssue(path, _describe(error)));
    }
  }

  static String _describe(Object error) => switch (error) {
        FileSystemException e => e.osError?.message.isNotEmpty == true
            ? e.osError!.message
            : e.message,
        _ => '$error',
      };

  Future<List<SourceEntry>> _list(FileSource source, String path) async {
    try {
      final local = source.localPath(path);
      if (local != null) return _listLocal(local);
      return await _gate.run(() => source.list(path));
    } catch (e) {
      _issue(path.isEmpty ? '/' : path, e);
      return const [];
    }
  }

  /// What [FileSource.list] returns for a local folder, without a round
  /// trip to the I/O thread for every entry. The scan runs in its own
  /// isolate, so blocking here costs the UI nothing; on a large tree it
  /// is several times faster.
  static List<SourceEntry> _listLocal(String dir) {
    final out = <SourceEntry>[];
    for (final entity in Directory(dir).listSync(followLinks: false)) {
      if (entity is Link) continue;
      FileStat? stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        stat = null;
      }
      out.add(SourceEntry(
        name: p.basename(entity.path),
        isDirectory: entity is Directory,
        size: stat?.size,
        modified: stat?.modified,
      ));
    }
    return out;
  }

  /// Reads a whole file, synchronously when it is on this machine.
  Future<Uint8List> _read(FileSource source, String path) {
    final local = source.localPath(path);
    if (local != null) return Future.value(File(local).readAsBytesSync());
    return _gate.run(() => source.read(path));
  }

  /// Adds the rules of [folder]'s `.gitignore` (when [entries] has one) to
  /// [chain].
  Future<GitignoreChain?> _withGitignore(FileSource source, String folder,
      List<SourceEntry> entries, GitignoreChain? chain) async {
    if (!options.respectGitignore) return chain;
    final has = entries.any((e) => !e.isDirectory && e.name == '.gitignore');
    if (!has) return chain;
    try {
      final bytes = await _read(source, _join(folder, '.gitignore'));
      final rules = _rules.parseGitignore(_decodeText(bytes));
      return rules.isEmpty ? chain : GitignoreChain.push(chain, folder, rules);
    } catch (e) {
      _issue(_join(folder, '.gitignore'), e);
      return chain;
    }
  }

  bool _isIgnored(String path, SourceEntry? l, SourceEntry? r,
      GitignoreChain? leftChain, GitignoreChain? rightChain) {
    bool check(bool isDirectory) =>
        _rules.isIgnored(path, isDirectory: isDirectory) ||
        (leftChain?.isIgnored(path, isDirectory: isDirectory) ?? false) ||
        (rightChain?.isIgnored(path, isDirectory: isDirectory) ?? false);
    if (l != null && check(l.isDirectory)) return true;
    if (r != null && r.isDirectory != l?.isDirectory && check(r.isDirectory)) {
      return true;
    }
    return false;
  }

  /// Compares the folder at [path], which exists on the sides whose entry
  /// is given.
  Future<CompareNode> _compareFolder(
    String path,
    String name, {
    required SourceEntry? leftEntry,
    required SourceEntry? rightEntry,
    required GitignoreChain? leftChain,
    required GitignoreChain? rightChain,
  }) async {
    final onLeft = leftEntry != null, onRight = rightEntry != null;
    final leftList = onLeft ? await _list(left, path) : const <SourceEntry>[];
    final rightList =
        onRight ? await _list(right, path) : const <SourceEntry>[];
    if (onLeft) {
      leftChain = await _withGitignore(left, path, leftList, leftChain);
    }
    if (onRight) {
      rightChain = await _withGitignore(right, path, rightList, rightChain);
    }

    final node = CompareNode(
      name: name,
      relativePath: path,
      isDirectory: true,
      status: onLeft && onRight
          ? EntryStatus.identical
          : onLeft
              ? EntryStatus.onlyLeft
              : EntryStatus.onlyRight,
      leftModified: leftEntry?.modified,
      rightModified: rightEntry?.modified,
    );

    final leftByName = {for (final e in leftList) e.name: e};
    final rightByName = {for (final e in rightList) e.name: e};
    final names = <String>{...leftByName.keys, ...rightByName.keys};

    // Files present on both sides are compared together afterwards, and
    // subfolders after that, so slow sources can overlap their requests.
    final pairs = <(String, SourceEntry, SourceEntry)>[];
    final folders = <Future<CompareNode> Function()>[];
    final children = <CompareNode>[];
    for (final childName in names) {
      final l = leftByName[childName], r = rightByName[childName];
      final childPath = _join(path, childName);
      if (_isIgnored(childPath, l, r, leftChain, rightChain)) {
        _ignoredCount++;
        if (_ignoredPaths.length < _maxIgnoredPaths) {
          _ignoredPaths.add(childPath);
        }
        continue;
      }
      if (l != null && r != null) {
        if (l.isDirectory && r.isDirectory) {
          folders.add(() => _compareFolder(childPath, childName,
              leftEntry: l,
              rightEntry: r,
              leftChain: leftChain,
              rightChain: rightChain));
        } else if (!l.isDirectory && !r.isDirectory) {
          pairs.add((childPath, l, r));
        } else {
          folders.add(() => _typeConflict(
              childPath, childName, l, r, leftChain, rightChain));
        }
      } else {
        final entry = (l ?? r)!;
        final side = l != null ? Side.left : Side.right;
        if (entry.isDirectory) {
          folders.add(() => _compareFolder(childPath, childName,
              leftEntry: l,
              rightEntry: r,
              leftChain: leftChain,
              rightChain: rightChain));
        } else {
          _tick(childPath);
          children.add(_oneSidedFile(childPath, childName, entry, side));
        }
      }
    }

    children.addAll(await _comparePairs(pairs));
    if (_bothLocal) {
      for (final folder in folders) {
        children.add(await folder());
      }
    } else {
      children.addAll(await Future.wait([for (final f in folders) f()]));
    }
    sortDirsFirst(children);
    node.children.addAll(children);

    var leftTotal = 0, rightTotal = 0;
    for (final child in children) {
      if (child.isDirectory) {
        node.identicalCount += child.identicalCount;
        node.modifiedCount += child.modifiedCount;
        node.onlyLeftCount += child.onlyLeftCount;
        node.onlyRightCount += child.onlyRightCount;
        if (child.children.isEmpty) child._countInto(node);
      } else {
        child._countInto(node);
      }
      leftTotal += child.leftSize ?? 0;
      rightTotal += child.rightSize ?? 0;
    }
    if (onLeft) node.leftSize = leftTotal;
    if (onRight) node.rightSize = rightTotal;
    if (onLeft && onRight && node.changedCount > 0) {
      node.status = EntryStatus.modified;
    }
    return node;
  }

  /// A file on one side and a folder on the other: one modified entry,
  /// carrying the folder's contents for sync.
  Future<CompareNode> _typeConflict(
      String path,
      String name,
      SourceEntry l,
      SourceEntry r,
      GitignoreChain? leftChain,
      GitignoreChain? rightChain) async {
    final folderSide = l.isDirectory ? Side.left : Side.right;
    final folder = await _compareFolder(path, name,
        leftEntry: folderSide == Side.left ? l : null,
        rightEntry: folderSide == Side.right ? r : null,
        leftChain: leftChain,
        rightChain: rightChain);
    _tick(path);
    return CompareNode(
      name: name,
      relativePath: path,
      isDirectory: false,
      status: EntryStatus.modified,
      folderSide: folderSide,
      leftSize: folderSide == Side.left ? folder.leftSize : l.size,
      rightSize: folderSide == Side.right ? folder.rightSize : r.size,
      leftModified: l.modified,
      rightModified: r.modified,
      children: folder.children,
    );
  }

  CompareNode _oneSidedFile(
          String path, String name, SourceEntry entry, Side side) =>
      CompareNode(
        name: name,
        relativePath: path,
        isDirectory: false,
        status:
            side == Side.left ? EntryStatus.onlyLeft : EntryStatus.onlyRight,
        leftSize: side == Side.left ? entry.size : null,
        rightSize: side == Side.right ? entry.size : null,
        leftModified: side == Side.left ? entry.modified : null,
        rightModified: side == Side.right ? entry.modified : null,
      );

  Future<List<CompareNode>> _comparePairs(
      List<(String, SourceEntry, SourceEntry)> pairs) async {
    final out = List<CompareNode?>.filled(pairs.length, null);
    // Local files compare with synchronous reads, which gain nothing from
    // overlapping; remote ones wait on the network, which does.
    final width = _bothLocal ? 1 : 6;
    var next = 0;
    Future<void> worker() async {
      while (next < pairs.length) {
        final i = next++;
        final (path, l, r) = pairs[i];
        out[i] = await _compareFile(path, l, r);
        _tick(path);
      }
    }

    await Future.wait([for (var i = 0; i < width; i++) worker()]);
    return out.cast<CompareNode>();
  }

  Future<CompareNode> _compareFile(
      String path, SourceEntry l, SourceEntry r) async {
    (EntryStatus, int?, int?) outcome;
    try {
      outcome = await _fileOutcome(path, l, r);
    } catch (e) {
      _issue(path, e);
      outcome = (EntryStatus.modified, null, null);
    }
    final (status, added, removed) = outcome;
    return CompareNode(
      name: l.name,
      relativePath: path,
      isDirectory: false,
      status: status,
      leftSize: l.size,
      rightSize: r.size,
      leftModified: l.modified,
      rightModified: r.modified,
      addedLines: added,
      removedLines: removed,
    );
  }

  /// The status of a file present on both sides, with line stats when it
  /// is a modified text file small enough to diff.
  Future<(EntryStatus, int?, int?)> _fileOutcome(
      String path, SourceEntry l, SourceEntry r) async {
    final ls = l.size, rs = r.size;
    if (options.quick && l.modified != null && r.modified != null) {
      final same = ls == rs &&
          l.modified!.difference(r.modified!).abs() < quickCompareTolerance;
      return (same ? EntryStatus.identical : EntryStatus.modified, null, null);
    }

    if (ls == null || rs == null) {
      // Sizes unknown (the listing could not stat them): read to decide.
      final same =
          bytesEqual(await _read(left, path), await _read(right, path));
      return (same ? EntryStatus.identical : EntryStatus.modified, null, null);
    }
    final small = ls <= _statsMaxBytes && rs <= _statsMaxBytes;
    final textRules = !options.compareOptions.isExact;
    Uint8List? lb, rb;

    if (ls == rs) {
      final lp = left.localPath(path), rp = right.localPath(path);
      if (!small && lp != null && rp != null) {
        // Too big to hold twice: chunked, stopping at the first difference.
        if (sameLocalFile(lp, rp)) return (EntryStatus.identical, null, null);
      } else {
        lb = await _read(left, path);
        rb = await _read(right, path);
        if (bytesEqual(lb, rb)) return (EntryStatus.identical, null, null);
      }
    }

    final readable =
        small || (textRules && ls <= _textMaxBytes && rs <= _textMaxBytes);
    if (!readable) return (EntryStatus.modified, null, null);
    lb ??= await _read(left, path);
    rb ??= await _read(right, path);
    if (looksBinary(lb) || looksBinary(rb)) {
      return (EntryStatus.modified, null, null);
    }

    final o = options.compareOptions;
    final leftKeys = lineKeys(_decodeText(lb), o);
    final rightKeys = lineKeys(_decodeText(rb), o);
    if (textRules && _listEquals(leftKeys, rightKeys)) {
      return (EntryStatus.identical, null, null);
    }
    if (!small) return (EntryStatus.modified, null, null);
    var added = 0, removed = 0;
    for (final chunk in diffLines(leftKeys, rightKeys)) {
      if (chunk.op == DiffOp.insert) added += chunk.lines.length;
      if (chunk.op == DiffOp.delete) removed += chunk.lines.length;
    }
    return (EntryStatus.modified, added, removed);
  }
}

String _join(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';

/// Meld-style ordering: directories first, then files, both in natural
/// name order.
void sortDirsFirst(List<CompareNode> children) {
  children.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return compareNatural(a.name, b.name);
  });
}

/// The keys two text files are compared by under [options]: each line
/// normalized, with blank lines dropped when the rules ignore them.
List<String> lineKeys(String text, CompareOptions options) {
  final lines = splitLines(text);
  if (options.isExact) return lines;
  final out = <String>[];
  for (final line in lines) {
    final key = options.normalize(line);
    if (options.ignoreBlankLines && key.isEmpty) continue;
    out.add(key);
  }
  return out;
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A NUL byte in the first 8 kB marks a file as binary, as git does.
bool looksBinary(List<int> bytes) {
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

/// Compares eight bytes at a time where the buffers allow it.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var i = 0;
  if (a.offsetInBytes % 8 == 0 && b.offsetInBytes % 8 == 0) {
    final words = a.length ~/ 8;
    final wa = a.buffer.asUint64List(a.offsetInBytes, words);
    final wb = b.buffer.asUint64List(b.offsetInBytes, words);
    for (var w = 0; w < words; w++) {
      if (wa[w] != wb[w]) return false;
    }
    i = words * 8;
  }
  for (; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Chunked comparison of two local files, stopping at the first
/// difference. Synchronous: it runs in the scan isolate, where blocking is
/// cheaper than a round trip per chunk.
bool sameLocalFile(String a, String b) {
  const chunkSize = 256 * 1024;
  final ra = File(a).openSync();
  final rb = File(b).openSync();
  try {
    while (true) {
      final ba = ra.readSync(chunkSize);
      final bb = rb.readSync(chunkSize);
      if (!bytesEqual(ba, bb)) return false;
      if (ba.isEmpty) return true;
    }
  } finally {
    ra.closeSync();
    rb.closeSync();
  }
}

/// Limits how many requests a remote source has in flight at once.
class _Gate {
  _Gate(this.width);

  final int width;
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= width) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      // Hand the slot straight to the next waiter, or free it.
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
