/// Uniform file access for every kind of [SourceSpec], so the folder
/// scanner, the diff views and folder sync work the same on local folders,
/// archives and SFTP servers.
library;

import 'dart:typed_data';

import 'archive_source.dart';
import 'local_source.dart';
import 'sftp_source.dart';
import 'source_spec.dart';

export 'source_spec.dart';

class SourceEntry {
  const SourceEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;
}

/// A file tree rooted at a [SourceSpec]'s location. Relative paths use `/`
/// separators; the empty path is the root itself, which may be a file
/// (when a file comparison opens one side) or a directory.
abstract class FileSource {
  /// Opens the right implementation for [spec]. Works in any isolate.
  static Future<FileSource> open(SourceSpec spec) => switch (spec) {
        LocalSource s => Future.value(LocalFileSource(s)),
        ArchiveSource s => ArchiveFileSource.open(s),
        SftpSource s => SftpFileSource.open(s),
      };

  SourceSpec get spec;

  /// False for archives, and for servers or folders that refuse writes.
  bool get writable;

  /// Null when nothing exists at [relative].
  Future<SourceEntry?> stat(String relative);

  /// Entries of the directory at [relative], unsorted. Symbolic links are
  /// left out. Throws when the directory cannot be read.
  Future<List<SourceEntry>> list(String relative);

  Future<Uint8List> read(String relative);

  /// Writes the whole file, creating missing parent directories.
  Future<void> write(String relative, List<int> bytes);

  /// Deletes a file, or a directory with everything in it.
  Future<void> delete(String relative);

  Future<void> createDirectory(String relative);

  /// The path on this machine, when there is one (for file watching,
  /// "Show in file manager", "Open in external editor").
  String? localPath(String relative);

  Future<void> close();
}
