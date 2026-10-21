import 'dart:convert';
import 'dart:typed_data';

import 'package:delta_view/compare/sources/file_source.dart';

/// A [FileSource] held in memory, for driving the scanner and sync without
/// touching disk. Records every read so tests can check what was opened.
class MemorySource implements FileSource {
  MemorySource(
    Map<String, Object> files, {
    this.writable = true,
    String name = 'mem',
    DateTime? time,
  })  : spec = SftpSource(host: name, username: 'test', path: '/$name'),
        _time = time ?? DateTime(2026, 1, 1) {
    files.forEach((path, content) {
      if (content is Folder) {
        _folders.add(path);
      } else {
        put(path, content);
      }
    });
  }

  @override
  final SftpSource spec;

  @override
  final bool writable;

  final DateTime _time;
  final _files = <String, Uint8List>{};
  final _times = <String, DateTime>{};
  final _folders = <String>{''};

  /// Paths read, in order.
  final reads = <String>[];

  /// Paths listed, in order.
  final listed = <String>[];

  void put(String path, Object content, {DateTime? modified}) {
    _files[path] = switch (content) {
      String s => Uint8List.fromList(utf8.encode(s)),
      List<int> b => Uint8List.fromList(b),
      _ => throw ArgumentError(content),
    };
    _times[path] = modified ?? _time;
    _addParents(path);
  }

  void touch(String path, DateTime modified) => _times[path] = modified;

  String? text(String path) =>
      _files[path] == null ? null : utf8.decode(_files[path]!);

  bool hasFolder(String path) => _folders.contains(path);

  Iterable<String> get files => _files.keys;

  void _addParents(String path) {
    var i = path.lastIndexOf('/');
    while (i > 0) {
      _folders.add(path.substring(0, i));
      i = path.lastIndexOf('/', i - 1);
    }
  }

  static String _parent(String path) =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  static String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

  @override
  Future<SourceEntry?> stat(String relative) async {
    if (_folders.contains(relative)) {
      return SourceEntry(
          name: _name(relative), isDirectory: true, modified: _time);
    }
    final bytes = _files[relative];
    if (bytes == null) return null;
    return SourceEntry(
      name: _name(relative),
      isDirectory: false,
      size: bytes.length,
      modified: _times[relative],
    );
  }

  @override
  Future<List<SourceEntry>> list(String relative) async {
    if (!_folders.contains(relative)) {
      throw StateError('No folder $relative');
    }
    listed.add(relative);
    return [
      for (final f in _folders)
        if (f.isNotEmpty && _parent(f) == relative)
          SourceEntry(name: _name(f), isDirectory: true, modified: _time),
      for (final e in _files.entries)
        if (_parent(e.key) == relative)
          SourceEntry(
            name: _name(e.key),
            isDirectory: false,
            size: e.value.length,
            modified: _times[e.key],
          ),
    ];
  }

  @override
  Future<Uint8List> read(String relative) async {
    reads.add(relative);
    final bytes = _files[relative];
    if (bytes == null) throw StateError('No file $relative');
    return bytes;
  }

  @override
  Future<void> write(String relative, List<int> bytes) async {
    if (!writable) throw UnsupportedError('read-only');
    put(relative, bytes, modified: DateTime.now());
  }

  @override
  Future<void> delete(String relative) async {
    _files.removeWhere((k, _) => k == relative || k.startsWith('$relative/'));
    _folders.removeWhere((k) => k == relative || k.startsWith('$relative/'));
  }

  @override
  Future<void> createDirectory(String relative) async {
    _folders.add(relative);
    _addParents(relative);
  }

  @override
  String? localPath(String relative) => null;

  @override
  Future<void> close() async {}
}

/// Marks an empty folder in a [MemorySource] layout.
class Folder {
  const Folder();
}
