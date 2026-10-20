import 'file_source.dart';

/// Read-only view of a path inside an archive.
///
/// Placeholder until archive support lands: opening one fails with a clear
/// message instead of crashing.
abstract class ArchiveFileSource implements FileSource {
  static Future<FileSource> open(ArchiveSource spec) =>
      Future.error(UnsupportedError('Archive comparison is not available yet.'));
}
