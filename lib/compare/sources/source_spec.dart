/// Where one side of a comparison lives: a local path, a path inside an
/// archive, or a path on an SFTP server.
///
/// A spec is plain data. It can be sent to another isolate (the folder
/// scanner opens its own [FileSource] from it) and saved as JSON (recent
/// comparisons, session restore). Secrets are never written to JSON.
library;

import 'package:path/path.dart' as p;

sealed class SourceSpec {
  const SourceSpec();

  /// Short name for tabs and cards, e.g. the last path component.
  String get label;

  /// Full human-readable location, e.g. `user@host:/srv/app` or
  /// `/tmp/release.zip › src/main.dart`.
  String get description;

  /// True for a plain path on this machine.
  bool get isLocal => false;

  /// The spec of an entry inside this one. [relative] uses `/` separators.
  SourceSpec child(String relative);

  Map<String, Object?> toJson();

  static SourceSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    return switch (json['kind']) {
      'local' => json['path'] is String ? LocalSource(json['path'] as String) : null,
      'archive' => json['archive'] is String
          ? ArchiveSource(json['archive'] as String,
              innerPath: (json['inner'] as String?) ?? '')
          : null,
      'sftp' => SftpSource.fromJson(json),
      _ => null,
    };
  }
}

class LocalSource extends SourceSpec {
  const LocalSource(this.path);

  final String path;

  @override
  String get label => p.basename(path).isEmpty ? path : p.basename(path);

  @override
  String get description => path;

  @override
  bool get isLocal => true;

  @override
  LocalSource child(String relative) => relative.isEmpty
      ? this
      : LocalSource(p.joinAll([path, ...relative.split('/')]));

  @override
  Map<String, Object?> toJson() => {'kind': 'local', 'path': path};

  @override
  bool operator ==(Object other) => other is LocalSource && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A path inside a zip / tar / tar.gz / tar.bz2 / tar.xz archive. Read-only.
class ArchiveSource extends SourceSpec {
  const ArchiveSource(this.archivePath, {this.innerPath = ''});

  /// The archive file on this machine.
  final String archivePath;

  /// Path inside the archive with `/` separators; empty for the root.
  final String innerPath;

  @override
  String get label => innerPath.isEmpty
      ? p.basename(archivePath)
      : p.posix.basename(innerPath);

  @override
  String get description => innerPath.isEmpty
      ? archivePath
      : '$archivePath › $innerPath';

  @override
  ArchiveSource child(String relative) => relative.isEmpty
      ? this
      : ArchiveSource(archivePath,
          innerPath:
              innerPath.isEmpty ? relative : p.posix.join(innerPath, relative));

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'archive', 'archive': archivePath, 'inner': innerPath};

  @override
  bool operator ==(Object other) =>
      other is ArchiveSource &&
      other.archivePath == archivePath &&
      other.innerPath == innerPath;

  @override
  int get hashCode => Object.hash(archivePath, innerPath);
}

/// Credentials for an SFTP connection. Held in memory only.
class SftpSecret {
  const SftpSecret({this.password, this.privateKeyPem, this.passphrase});

  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}

/// A path on an SFTP server.
class SftpSource extends SourceSpec {
  const SftpSource({
    required this.host,
    this.port = 22,
    required this.username,
    required this.path,
    this.hostKeySha256,
    this.secret,
  });

  final String host;
  final int port;
  final String username;

  /// Absolute remote path with `/` separators.
  final String path;

  /// The server host key fingerprint the user accepted (base64 SHA-256, as
  /// OpenSSH prints it without the `SHA256:` prefix). A connection whose
  /// key does not match is refused.
  final String? hostKeySha256;

  /// Not serialized. Must be filled in before [FileSource.open].
  final SftpSecret? secret;

  String get authority =>
      port == 22 ? '$username@$host' : '$username@$host:$port';

  @override
  String get label => p.posix.basename(path).isEmpty ? host : p.posix.basename(path);

  @override
  String get description => '$authority:$path';

  @override
  SftpSource child(String relative) => relative.isEmpty
      ? this
      : withPath(p.posix.join(path, relative));

  SftpSource withPath(String newPath) => SftpSource(
        host: host,
        port: port,
        username: username,
        path: newPath,
        hostKeySha256: hostKeySha256,
        secret: secret,
      );

  SftpSource withSecret(SftpSecret? newSecret, {String? hostKey}) => SftpSource(
        host: host,
        port: port,
        username: username,
        path: path,
        hostKeySha256: hostKey ?? hostKeySha256,
        secret: newSecret,
      );

  @override
  Map<String, Object?> toJson() => {
        'kind': 'sftp',
        'host': host,
        'port': port,
        'username': username,
        'path': path,
        'hostKeySha256': hostKeySha256,
      };

  static SftpSource? fromJson(Map json) {
    final host = json['host'], user = json['username'], path = json['path'];
    if (host is! String || user is! String || path is! String) return null;
    return SftpSource(
      host: host,
      port: json['port'] is int ? json['port'] as int : 22,
      username: user,
      path: path,
      hostKeySha256: json['hostKeySha256'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SftpSource &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.path == path;

  @override
  int get hashCode => Object.hash(host, port, username, path);
}
