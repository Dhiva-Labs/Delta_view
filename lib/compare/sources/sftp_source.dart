import 'file_source.dart';

/// Files on an SFTP server.
///
/// Placeholder until remote support lands: opening one fails with a clear
/// message instead of crashing.
abstract class SftpFileSource implements FileSource {
  static Future<FileSource> open(SftpSource spec) =>
      Future.error(UnsupportedError('Remote (SFTP) comparison is not available yet.'));
}
