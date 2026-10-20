/// Read-only access to the files inside a zip or tar archive (plain, or
/// compressed with gzip, bzip2, xz or zstd).
///
/// Opening an archive builds a directory index in a helper isolate, so a
/// big archive never stalls the caller. Entries are read on demand:
///
/// * zip: straight from the archive file, decompressing one entry per read;
/// * plain tar: straight from the archive file at the entry's offset;
/// * compressed tar: the archive is decompressed once while indexing, into
///   memory when it is small and into a scratch file next to the user's
///   cache otherwise, and entries are read from there. A compressed tar has
///   no index of its own, so this is what keeps reading many entries linear
///   instead of decompressing the archive again for every file.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'file_source.dart';

/// A friendly, specific reason an archive could not be opened or read.
class ArchiveSourceException implements Exception {
  const ArchiveSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns a path as stored in an archive (or typed by the user) into the
/// form the index uses: `/` separators, no leading `./` or `/`, no empty or
/// `.` segments, and `..` never climbing above the archive root.
String normalizeArchivePath(String raw) {
  final parts = <String>[];
  for (final segment in raw.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

class ArchiveFileSource implements FileSource {
  ArchiveFileSource._(this.spec, this._handle, this._root);

  /// Keep archives indexed for a while after the last source on them
  /// closes. Every file view opens (and closes) its own source, so without
  /// this, stepping through files in an archive would index it again for
  /// each one. Off by default so that a background isolate (the folder
  /// scanner) lets go of everything as soon as it is done; the UI turns it
  /// on for the main isolate.
  static bool keepRecentArchivesOpen = false;

  /// How long an unused archive stays indexed when
  /// [keepRecentArchivesOpen] is on.
  static Duration idleTimeout = const Duration(minutes: 2);

  /// Compressed tars up to this size (decompressed) are kept in memory;
  /// bigger ones are decompressed into a scratch file. Lowered by tests.
  static int memoryBudget = 64 * 1024 * 1024;

  /// Where those scratch files go; null for DeltaView's folder in the
  /// user's cache directory. Set by tests.
  static String? scratchDirectory;

  /// Opens the archive at [spec]'s path (or reuses its index) and roots the
  /// source at [ArchiveSource.innerPath], which may name a folder or a
  /// single file inside it.
  static Future<FileSource> open(ArchiveSource spec) async {
    final handle = await _ArchiveHandle.acquire(spec.archivePath);
    return ArchiveFileSource._(
        spec, handle, normalizeArchivePath(spec.innerPath));
  }

  @override
  final ArchiveSource spec;

  final _ArchiveHandle _handle;

  /// Normalized path of the source root inside the archive.
  final String _root;

  bool _closed = false;

  @override
  bool get writable => false;

  String _inner(String relative) {
    final rel = normalizeArchivePath(relative);
    if (_root.isEmpty) return rel;
    return rel.isEmpty ? _root : '$_root/$rel';
  }

  _ArchiveNode? _find(String relative) {
    _checkOpen();
    return _handle.find(_inner(relative));
  }

  void _checkOpen() {
    if (_closed) throw StateError('This archive source has been closed.');
  }

  String get _archiveName => p.basename(spec.archivePath);

  @override
  Future<SourceEntry?> stat(String relative) async {
    final node = _find(relative);
    if (node == null) return null;
    final inner = _inner(relative);
    return node.toEntry(inner.isEmpty ? _archiveName : p.posix.basename(inner));
  }

  @override
  Future<List<SourceEntry>> list(String relative) async {
    final node = _find(relative);
    final inner = _inner(relative);
    if (node == null) {
      throw ArchiveSourceException(
          '“${inner.isEmpty ? _archiveName : inner}” is not in $_archiveName.');
    }
    final children = node.children;
    if (children == null) {
      throw ArchiveSourceException('“$inner” in $_archiveName is a file, '
          'not a folder.');
    }
    return [
      for (final e in children.entries) e.value.toEntry(e.key),
    ];
  }

  @override
  Future<Uint8List> read(String relative) async {
    final node = _find(relative);
    final inner = _inner(relative);
    if (node == null) {
      throw ArchiveSourceException('“$inner” is not in $_archiveName.');
    }
    if (node.isDirectory) {
      throw ArchiveSourceException(
          '“${inner.isEmpty ? _archiveName : inner}” is a folder, not a file.');
    }
    return _handle.read(node, inner);
  }

  static const _readOnly = ArchiveSourceException(
      'Files inside an archive are read-only. Extract the archive to change '
      'them.');

  @override
  Future<void> write(String relative, List<int> bytes) =>
      Future.error(_readOnly);

  @override
  Future<void> delete(String relative) => Future.error(_readOnly);

  @override
  Future<void> createDirectory(String relative) => Future.error(_readOnly);

  @override
  String? localPath(String relative) => null;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handle.release();
  }
}

// ---------------------------------------------------------------------------
// Index

/// One entry of the archive's directory tree. Plain data, so a tree built
/// in the indexing isolate can be handed back whole.
class _ArchiveNode {
  _ArchiveNode.directory()
      : isDirectory = true,
        size = 0,
        offset = 0,
        storedSize = 0,
        method = 0,
        encrypted = false,
        children = {};

  _ArchiveNode.file({
    required this.size,
    required this.offset,
    this.modifiedMs,
    this.storedSize = 0,
    this.method = 0,
    this.encrypted = false,
  })  : isDirectory = false,
        children = null;

  final bool isDirectory;
  final int size;

  /// Milliseconds since the epoch, when the archive records it.
  int? modifiedMs;

  /// tar: where the entry's data starts in the tar stream.
  /// zip: where the entry's local header starts.
  final int offset;

  /// zip: compressed size and compression method of the entry.
  final int storedSize;
  final int method;

  /// zip: the entry is encrypted.
  final bool encrypted;

  final Map<String, _ArchiveNode>? children;

  SourceEntry toEntry(String name) => SourceEntry(
        name: name,
        isDirectory: isDirectory,
        size: isDirectory ? null : size,
        modified: modifiedMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modifiedMs!),
      );
}

/// Builds the tree from entries in archive order: implicit parent folders
/// are created on the way, and a later entry for the same path replaces an
/// earlier one (as `tar -x` would), except that a folder is never replaced
/// by a file of the same name.
class _TreeBuilder {
  final root = _ArchiveNode.directory();

  _ArchiveNode? find(String path) {
    var node = root;
    if (path.isEmpty) return node;
    for (final part in path.split('/')) {
      final next = node.children?[part];
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  _ArchiveNode _directory(List<String> parts) {
    var node = root;
    for (final part in parts) {
      final children = node.children!;
      var next = children[part];
      if (next == null || !next.isDirectory) {
        next = _ArchiveNode.directory();
        children[part] = next;
      }
      node = next;
    }
    return node;
  }

  void addDirectory(String path, {int? modifiedMs}) {
    if (path.isEmpty) return;
    final dir = _directory(path.split('/'));
    if (modifiedMs != null) dir.modifiedMs = modifiedMs;
  }

  void addFile(String path, _ArchiveNode node) {
    if (path.isEmpty) return;
    final parts = path.split('/');
    final parent = _directory(parts.sublist(0, parts.length - 1));
    final existing = parent.children![parts.last];
    if (existing != null && existing.isDirectory) return;
    parent.children![parts.last] = node;
  }
}

enum _Kind { zip, tar }

enum _Compression { none, gzip, bzip2, xz, zstd }

/// What the indexing isolate hands back.
class _IndexResult {
  _IndexResult({
    required this.kind,
    required this.root,
    this.memoryTar,
    this.spillFile,
  });

  final _Kind kind;
  final _ArchiveNode root;

  /// A small compressed tar, decompressed.
  final Uint8List? memoryTar;

  /// A large compressed tar, decompressed into this scratch file.
  final String? spillFile;
}

/// zip entries bigger than this are inflated in a helper isolate.
const _inlineInflateLimit = 8 * 1024 * 1024;

Future<_IndexResult> _buildIndex(String archivePath) async {
  final header = await _readHead(archivePath);
  final (kind, compression) = _detect(archivePath, header);
  // Statics are per isolate, so the settings travel with the closure.
  final spill = _SpillSettings(ArchiveFileSource.memoryBudget,
      ArchiveFileSource.scratchDirectory ?? p.join(_cacheRoot(), 'archives'));
  return Isolate.run(() => switch (kind) {
        _Kind.zip => _indexZip(archivePath),
        _Kind.tar => _indexTar(archivePath, compression, spill),
      });
}

class _SpillSettings {
  const _SpillSettings(this.memoryBudget, this.directory);

  final int memoryBudget;
  final String directory;
}

Future<Uint8List> _readHead(String path) async {
  final raf = await File(path).open();
  try {
    return await raf.read(512);
  } finally {
    await raf.close();
  }
}

bool _startsWith(Uint8List data, List<int> magic, [int at = 0]) {
  if (data.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (data[at + i] != magic[i]) return false;
  }
  return true;
}

(_Kind, _Compression) _detect(String path, Uint8List head) {
  if (_startsWith(head, const [0x50, 0x4b, 0x03, 0x04]) ||
      _startsWith(head, const [0x50, 0x4b, 0x05, 0x06]) ||
      _startsWith(head, const [0x50, 0x4b, 0x07, 0x08])) {
    return (_Kind.zip, _Compression.none);
  }
  if (_startsWith(head, const [0x1f, 0x8b])) {
    return (_Kind.tar, _Compression.gzip);
  }
  if (_startsWith(head, const [0x42, 0x5a, 0x68])) {
    return (_Kind.tar, _Compression.bzip2);
  }
  if (_startsWith(head, const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])) {
    return (_Kind.tar, _Compression.xz);
  }
  if (_startsWith(head, const [0x28, 0xb5, 0x2f, 0xfd])) {
    return (_Kind.tar, _Compression.zstd);
  }
  // "ustar" at offset 257 marks POSIX and GNU tars.
  if (_startsWith(head, const [0x75, 0x73, 0x74, 0x61, 0x72], 257)) {
    return (_Kind.tar, _Compression.none);
  }
  // Old-style tars have no magic, and self-extracting or prefixed zips do
  // not start with a zip header; go by the name for those.
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.tar')) return (_Kind.tar, _Compression.none);
  if (const ['.zip', '.jar', '.war', '.ear', '.apk', '.aar', '.whl', '.nupkg']
      .any(name.endsWith)) {
    return (_Kind.zip, _Compression.none);
  }
  throw ArchiveSourceException('“${p.basename(path)}” is not an archive '
      'DeltaView can open. Supported: zip, tar, tar.gz, tar.bz2, tar.xz.');
}

// ---- zip ----

_IndexResult _indexZip(String archivePath) {
  final input = InputFileStream(archivePath);
  try {
    final decoder = ZipDecoder();
    try {
      decoder.decodeStream(input);
    } on ArchiveException {
      throw _damaged(archivePath);
    } on RangeError {
      throw _damaged(archivePath);
    } on FormatException {
      throw _damaged(archivePath);
    }
    final tree = _TreeBuilder();
    for (final header in decoder.directory.fileHeaders) {
      final path = normalizeArchivePath(header.filename);
      if (path.isEmpty) continue;
      final modified = _zipModified(header);
      // A trailing slash marks a folder; DOS-made zips may instead set the
      // directory attribute.
      final isDirectory = header.filename.endsWith('/') ||
          header.filename.endsWith('\\') ||
          (header.versionMadeBy >> 8 == 0 &&
              header.externalFileAttributes & 0x10 != 0);
      if (isDirectory) {
        tree.addDirectory(path, modifiedMs: modified);
        continue;
      }
      // Unix-made zips keep the file type in the high external attributes.
      final unixType = (header.externalFileAttributes >> 16) & 0xf000;
      if (header.versionMadeBy >> 8 == 3) {
        if (unixType == 0xa000) continue; // symbolic link
        if (unixType == 0x4000) {
          tree.addDirectory(path, modifiedMs: modified);
          continue;
        }
      }
      tree.addFile(
        path,
        _ArchiveNode.file(
          size: header.uncompressedSize,
          offset: header.localHeaderOffset,
          storedSize: header.compressedSize,
          method: header.compressionMethod,
          encrypted: header.generalPurposeBitFlag & 1 != 0,
          modifiedMs: modified,
        ),
      );
    }
    return _IndexResult(kind: _Kind.zip, root: tree.root);
  } finally {
    input.closeSync();
  }
}

/// The entry's modification time: the Unix time in an extended timestamp
/// field when there is one, otherwise the DOS date and time (local time,
/// two-second resolution).
int? _zipModified(ZipFileHeader header) {
  final extra = header.extraField;
  if (extra != null) {
    var i = 0;
    while (i + 4 <= extra.length) {
      final id = extra[i] | extra[i + 1] << 8;
      final size = extra[i + 2] | extra[i + 3] << 8;
      final start = i + 4;
      if (id == 0x5455 && size >= 5 && start + 5 <= extra.length) {
        final flags = extra[start];
        if (flags & 1 != 0) {
          final seconds = ByteData.sublistView(extra, start + 1, start + 5)
              .getInt32(0, Endian.little);
          return seconds * 1000;
        }
      }
      i = start + size;
    }
  }
  final date = header.lastModifiedFileDate, time = header.lastModifiedFileTime;
  if (date == 0) return null;
  return DateTime(
    ((date >> 9) & 0x7f) + 1980,
    (date >> 5) & 0x0f,
    date & 0x1f,
    (time >> 11) & 0x1f,
    (time >> 5) & 0x3f,
    (time & 0x1f) * 2,
  ).millisecondsSinceEpoch;
}

// ---- tar ----

_IndexResult _indexTar(
    String archivePath, _Compression compression, _SpillSettings settings) {
  Uint8List? memory;
  String? spill;
  try {
    if (compression != _Compression.none) {
      (memory, spill) = _decompress(archivePath, compression, settings);
    }
    final InputStream input = memory != null
        ? InputMemoryStream(memory)
        : InputFileStream(spill ?? archivePath);
    try {
      final root = _tarTree(input, memory, p.basename(archivePath));
      return _IndexResult(
          kind: _Kind.tar, root: root, memoryTar: memory, spillFile: spill);
    } finally {
      if (input is InputFileStream) input.closeSync();
    }
  } catch (_) {
    if (spill != null) _deleteSpill(spill);
    rethrow;
  }
}

/// Decompresses the whole archive, into memory while it fits in
/// the memory budget and into a scratch file once it does not.
(Uint8List?, String?) _decompress(
    String archivePath, _Compression compression, _SpillSettings settings) {
  final source = InputFileStream(archivePath);
  RandomAccessFile? out;
  String? spillPath;
  try {
    final InputStream decoded = switch (compression) {
      _Compression.gzip => const GZipDecoder().decodeLazy(source),
      _Compression.bzip2 => BZip2Decoder().decodeLazy(source),
      _Compression.xz => XZDecoder().decodeLazy(source),
      _Compression.zstd => ZstdDecoder().decodeLazy(source),
      _Compression.none => source,
    };
    final memory = BytesBuilder(copy: false);
    while (!decoded.isEOS) {
      final chunk = decoded.readBytes(1 << 20).toUint8List();
      if (chunk.isEmpty) break;
      if (out == null &&
          memory.length + chunk.length > settings.memoryBudget) {
        spillPath = _newSpillPath(settings.directory);
        out = File(spillPath).openSync(mode: FileMode.writeOnly);
        out.writeFromSync(memory.takeBytes());
      }
      if (out != null) {
        out.writeFromSync(chunk);
      } else {
        memory.add(chunk);
      }
    }
    if (out != null) {
      out.closeSync();
      out = null;
      return (null, spillPath);
    }
    return (memory.takeBytes(), null);
  } on ArchiveException {
    throw _damaged(archivePath);
  } on FormatException {
    throw _damaged(archivePath);
  } on RangeError {
    throw _damaged(archivePath);
  } finally {
    out?.closeSync();
    source.closeSync();
    if (out != null && spillPath != null) _deleteSpill(spillPath);
  }
}

_ArchiveNode _tarTree(InputStream input, Uint8List? memory, String name) {
  final decoder = TarDecoder();
  try {
    decoder.decodeStream(input, verify: true);
  } on ArchiveException {
    throw ArchiveSourceException(
        '“$name” is not a tar archive, or it is damaged.');
  } on RangeError {
    throw ArchiveSourceException('“$name” is damaged or truncated.');
  }
  final tree = _TreeBuilder();
  for (final tf in decoder.files) {
    final path = normalizeArchivePath(tf.filename);
    if (path.isEmpty) continue;
    final modified = tf.lastModTime == 0 ? null : tf.lastModTime * 1000;
    switch (tf.typeFlag) {
      case TarFile.directory:
        tree.addDirectory(path, modifiedMs: modified);
      case TarFile.normalFile || '' || TarFile.contFile:
        // Old tars mark folders with a trailing slash only.
        if (tf.filename.endsWith('/')) {
          tree.addDirectory(path, modifiedMs: modified);
          continue;
        }
        tree.addFile(
          path,
          _ArchiveNode.file(
            size: tf.fileSize,
            offset: _dataOffset(tf.rawContent, memory),
            modifiedMs: modified,
          ),
        );
      case TarFile.hardLink:
        // The decoder rewrote the target relative to the link's folder.
        final target = tf.nameOfLinkedFile;
        if (target == null || target.isEmpty) continue;
        final resolved = normalizeArchivePath(
            p.posix.join(p.posix.dirname(tf.filename), target));
        final original = tree.find(resolved);
        if (original == null || original.isDirectory) continue;
        tree.addFile(
          path,
          _ArchiveNode.file(
            size: original.size,
            offset: original.offset,
            modifiedMs: modified ?? original.modifiedMs,
          ),
        );
      default:
        // Symbolic links, devices and FIFOs are left out.
        continue;
    }
  }
  return tree.root;
}

/// Where an entry's data starts in the tar stream it was decoded from.
int _dataOffset(InputStream? content, Uint8List? memory) {
  if (content is InputFileStream) return content.fileOffset;
  if (content is InputMemoryStream && memory != null) {
    final view = content.buffer;
    if (view != null) return view.offsetInBytes - memory.offsetInBytes;
  }
  return 0;
}

ArchiveSourceException _damaged(String archivePath) => ArchiveSourceException(
    '“${p.basename(archivePath)}” is damaged or truncated, or is not an '
    'archive DeltaView can open.');

// ---- scratch files ----

/// A fresh scratch file for a decompressed archive, under the user's cache
/// directory rather than the system temp directory, which is often a RAM
/// disk. Works in any isolate (no plugins).
String _newSpillPath(String directory) {
  final dir = Directory(directory);
  dir.createSync(recursive: true);
  _sweepStaleSpills(dir);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return p.join(dir.path, 'extract-$pid-$stamp-${identityHashCode(dir)}.tar');
}

String _cacheRoot() {
  final env = Platform.environment;
  String? base;
  if (Platform.isLinux) {
    base = env['XDG_CACHE_HOME'] ??
        (env['HOME'] == null ? null : p.join(env['HOME']!, '.cache'));
    if (base != null) return p.join(base, 'deltaview');
  } else if (Platform.isMacOS) {
    base = env['HOME'] == null
        ? null
        : p.join(env['HOME']!, 'Library', 'Caches');
    if (base != null) return p.join(base, 'DeltaView');
  } else if (Platform.isWindows) {
    base = env['LOCALAPPDATA'];
    if (base != null) return p.join(base, 'DeltaView', 'Cache');
  }
  return p.join(Directory.systemTemp.path, 'deltaview');
}

/// Removes scratch files left behind by a crash: any older than a day.
void _sweepStaleSpills(Directory dir) {
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  try {
    for (final entity in dir.listSync()) {
      if (entity is File && entity.statSync().modified.isBefore(cutoff)) {
        entity.deleteSync();
      }
    }
  } on FileSystemException {
    // Best effort.
  }
}

void _deleteSpill(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone, or held open on Windows; the sweep gets it later.
  }
}

// ---------------------------------------------------------------------------
// Open archives

/// An indexed archive, shared by every source open on it in this isolate.
class _ArchiveHandle {
  _ArchiveHandle._(this.archivePath, this._stamp, _IndexResult index)
      : _kind = index.kind,
        _root = index.root,
        _memoryTar = index.memoryTar,
        _spillFile = index.spillFile;

  static final _open = <String, _ArchiveHandle>{};
  static final _loading = <String, Future<_ArchiveHandle>>{};

  final String archivePath;
  final (int, DateTime) _stamp;
  final _Kind _kind;
  final _ArchiveNode _root;
  Uint8List? _memoryTar;
  final String? _spillFile;

  int _leases = 0;
  Timer? _idle;
  bool _retired = false;
  bool _disposed = false;

  static Future<_ArchiveHandle> acquire(String archivePath) async {
    final name = p.basename(archivePath);
    final FileStat stat;
    try {
      stat = await FileStat.stat(archivePath);
    } on FileSystemException catch (e) {
      throw ArchiveSourceException('Could not read “$name”: ${e.message}.');
    }
    switch (stat.type) {
      case FileSystemEntityType.notFound:
        throw ArchiveSourceException('The archive “$name” no longer exists.');
      case FileSystemEntityType.directory:
        throw ArchiveSourceException('“$name” is a folder, not an archive.');
      default:
        break;
    }
    final stamp = (stat.size, stat.modified);

    final cached = _open[archivePath];
    if (cached != null) {
      if (cached._stamp == stamp) return cached.._lease();
      // The archive changed on disk: index it again, and let sources still
      // open on the old index finish with it.
      _open.remove(archivePath);
      cached._retire();
    }

    final loading = _loading[archivePath];
    if (loading != null) return (await loading).._lease();

    final future = _load(archivePath, stamp);
    _loading[archivePath] = future;
    try {
      final handle = await future;
      _open[archivePath] = handle;
      return handle.._lease();
    } finally {
      if (identical(_loading[archivePath], future)) {
        _loading.remove(archivePath);
      }
    }
  }

  static Future<_ArchiveHandle> _load(
      String archivePath, (int, DateTime) stamp) async {
    try {
      return _ArchiveHandle._(archivePath, stamp, await _buildIndex(archivePath));
    } on ArchiveSourceException {
      rethrow;
    } on FileSystemException catch (e) {
      throw ArchiveSourceException(
          'Could not read “${p.basename(archivePath)}”: ${e.message}.');
    } catch (e) {
      throw _damaged(archivePath);
    }
  }

  _ArchiveNode? find(String path) {
    var node = _root;
    if (path.isEmpty) return node;
    for (final part in path.split('/')) {
      final next = node.children?[part];
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  void _lease() {
    _idle?.cancel();
    _idle = null;
    _leases++;
  }

  void release() {
    if (_leases > 0) _leases--;
    if (_leases > 0) return;
    if (_retired || !ArchiveFileSource.keepRecentArchivesOpen) {
      _dispose();
    } else {
      _idle?.cancel();
      _idle = Timer(ArchiveFileSource.idleTimeout, _dispose);
    }
  }

  void _retire() {
    _retired = true;
    if (_leases == 0) _dispose();
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _idle?.cancel();
    if (identical(_open[archivePath], this)) _open.remove(archivePath);
    _memoryTar = null;
    final spill = _spillFile;
    if (spill != null) _deleteSpill(spill);
  }

  Future<Uint8List> read(_ArchiveNode node, String inner) async {
    try {
      return switch (_kind) {
        _Kind.tar => await _readTar(node),
        _Kind.zip => await _readZip(node, inner),
      };
    } on ArchiveSourceException {
      rethrow;
    } on FileSystemException catch (e) {
      throw ArchiveSourceException('Could not read “$inner” from '
          '${p.basename(archivePath)}: ${e.message}.');
    } catch (_) {
      throw ArchiveSourceException('“$inner” in ${p.basename(archivePath)} '
          'is damaged and cannot be read.');
    }
  }

  Future<Uint8List> _readTar(_ArchiveNode node) async {
    final memory = _memoryTar;
    if (memory != null) {
      return Uint8List.fromList(
          Uint8List.sublistView(memory, node.offset, node.offset + node.size));
    }
    return _readRange(_spillFile ?? archivePath, node.offset, node.size);
  }

  Future<Uint8List> _readZip(_ArchiveNode node, String inner) async {
    if (node.encrypted) {
      throw ArchiveSourceException('“$inner” is password-protected in '
          '${p.basename(archivePath)}. DeltaView cannot read encrypted '
          'entries.');
    }
    final local = await _readRange(archivePath, node.offset, 30);
    final view = ByteData.sublistView(local);
    if (local.length < 30 || view.getUint32(0, Endian.little) != 0x04034b50) {
      // An offset that does not land on a local header (a zip with data
      // in front of it, say): let the archive package find the entry.
      return _readZipEntryWithPackage(archivePath, inner);
    }
    final nameLength = view.getUint16(26, Endian.little);
    final extraLength = view.getUint16(28, Endian.little);
    final data = await _readRange(archivePath,
        node.offset + 30 + nameLength + extraLength, node.storedSize);
    switch (node.method) {
      case 0: // stored
        return data;
      case 8: // deflate
        if (node.size <= _inlineInflateLimit) return _inflate(data);
        return Isolate.run(() => _inflate(data));
      default:
        return _readZipEntryWithPackage(archivePath, inner);
    }
  }

  static Uint8List _inflate(Uint8List data) {
    final out = ZLibCodec(raw: true).decode(data);
    return out is Uint8List ? out : Uint8List.fromList(out);
  }

  /// Reads an entry the slow, general way (bzip2, zstd or lzma compressed
  /// entries), off the calling isolate.
  static Future<Uint8List> _readZipEntryWithPackage(
      String archivePath, String inner) {
    return Isolate.run(() {
      final input = InputFileStream(archivePath);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final file in archive.files) {
          if (normalizeArchivePath(file.name) == inner) {
            final bytes = file.readBytes();
            if (bytes == null) break;
            return bytes;
          }
        }
        throw ArchiveSourceException('“$inner” is stored in a way DeltaView '
            'cannot decompress.');
      } finally {
        input.closeSync();
      }
    });
  }

  static Future<Uint8List> _readRange(String path, int offset, int length) async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      final out = Uint8List(length);
      var filled = 0;
      while (filled < length) {
        final n = await raf.readInto(out, filled, length);
        if (n <= 0) break;
        filled += n;
      }
      return filled == length ? out : Uint8List.sublistView(out, 0, filled);
    } finally {
      await raf.close();
    }
  }
}
