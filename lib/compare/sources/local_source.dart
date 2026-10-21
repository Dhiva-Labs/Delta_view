import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'file_source.dart';

class LocalFileSource implements FileSource {
  LocalFileSource(this.spec);

  @override
  final LocalSource spec;

  @override
  bool get writable => true;

  String _abs(String relative) => relative.isEmpty
      ? spec.path
      : p.joinAll([spec.path, ...relative.split('/')]);

  @override
  String? localPath(String relative) => _abs(relative);

  @override
  Future<SourceEntry?> stat(String relative) async {
    final path = _abs(relative);
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return SourceEntry(
      name: p.basename(path),
      isDirectory: stat.type == FileSystemEntityType.directory,
      size: stat.size,
      modified: stat.modified,
    );
  }

  @override
  Future<List<SourceEntry>> list(String relative) async {
    final out = <SourceEntry>[];
    await for (final entity
        in Directory(_abs(relative)).list(followLinks: false)) {
      if (entity is Link) continue;
      FileStat? stat;
      try {
        stat = await entity.stat();
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

  @override
  Future<Uint8List> read(String relative) => File(_abs(relative)).readAsBytes();

  @override
  Future<void> write(String relative, List<int> bytes) async {
    final file = File(_abs(relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String relative) async {
    final path = _abs(relative);
    final type = await FileSystemEntity.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        return;
      default:
        await File(path).delete();
    }
  }

  @override
  Future<void> createDirectory(String relative) =>
      Directory(_abs(relative)).create(recursive: true);

  @override
  Future<void> close() async {}
}
