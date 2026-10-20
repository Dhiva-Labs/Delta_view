/// Files on an SFTP server, through dartssh2.
///
/// Security: [SftpFileSource.open] never trusts a host key on first use. It
/// connects only when the server presents exactly the key the spec carries
/// ([SftpSource.hostKeySha256]); otherwise it hangs up before sending any
/// credentials and throws [SftpHostKeyNotTrusted] or [SftpHostKeyMismatch]
/// with the key the server offered, so the UI can ask the user and try
/// again. Deciding to trust a key is the UI's job, never this file's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'file_source.dart';

// ---------------------------------------------------------------------------
// Errors

/// Why an SFTP source could not be opened or used. [message] is written for
/// the user.
abstract class SftpSourceException implements Exception {
  const SftpSourceException();

  String get message;

  @override
  String toString() => message;
}

/// The spec carries no password or key: ask the user, then open again.
class SftpCredentialsRequired extends SftpSourceException {
  const SftpCredentialsRequired(this.authority);

  final String authority;

  @override
  String get message => 'Sign in to $authority to continue.';
}

/// The connection was refused because of the server's host key. Nothing
/// was sent to the server beyond the key exchange.
abstract class SftpHostKeyRejected extends SftpSourceException {
  const SftpHostKeyRejected({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  final String host;
  final int port;

  /// The host key algorithm the server used, e.g. `ssh-ed25519`.
  final String keyType;

  /// The key the server presented: base64 SHA-256, no padding, no prefix.
  final String fingerprint;
}

/// The spec names no accepted key yet ([SftpSource.hostKeySha256] is null).
class SftpHostKeyNotTrusted extends SftpHostKeyRejected {
  const SftpHostKeyNotTrusted({
    required super.host,
    required super.port,
    required super.keyType,
    required super.fingerprint,
  });

  @override
  String get message => 'The identity of $host has not been confirmed yet.';
}

/// The server presented a different key from the one accepted before.
/// Either the server was reinstalled or re-keyed, or someone is
/// intercepting the connection.
class SftpHostKeyMismatch extends SftpHostKeyRejected {
  const SftpHostKeyMismatch({
    required super.host,
    required super.port,
    required super.keyType,
    required super.fingerprint,
    required this.expected,
  });

  final String expected;

  @override
  String get message => 'The host key of $host has changed. DeltaView '
      'refused to connect, because this can mean someone is intercepting '
      'the connection.';
}

class SftpAuthFailed extends SftpSourceException {
  const SftpAuthFailed(this.authority, {required this.usedKey});

  final String authority;
  final bool usedKey;

  @override
  String get message => usedKey
      ? 'The server did not accept the key for $authority.'
      : 'The server did not accept the password for $authority.';
}

/// The private key could not be used: wrong passphrase, missing
/// passphrase, or not a key at all.
class SftpPrivateKeyError extends SftpSourceException {
  const SftpPrivateKeyError(this.message, {this.needsPassphrase = false});

  @override
  final String message;

  final bool needsPassphrase;
}

class SftpHostUnreachable extends SftpSourceException {
  const SftpHostUnreachable(this.host, this.port, this.reason);

  final String host;
  final int port;
  final String reason;

  @override
  String get message => 'Could not reach ${port == 22 ? host : '$host:$port'}: '
      '$reason.';
}

/// The SSH or SFTP session failed for another reason (protocol error, no
/// SFTP on the server, connection dropped).
class SftpConnectionFailed extends SftpSourceException {
  const SftpConnectionFailed(this.message);

  @override
  final String message;
}

class SftpPermissionDenied extends SftpSourceException {
  const SftpPermissionDenied(this.path);

  final String path;

  @override
  String get message => 'Permission denied: $path';
}

class SftpOperationFailed extends SftpSourceException {
  const SftpOperationFailed(this.message);

  @override
  final String message;
}

// ---------------------------------------------------------------------------
// Source

class SftpFileSource implements FileSource {
  SftpFileSource._(this.spec, this._secret, this._connection, this._writable);

  /// Share one connection per server among the sources open on it, and
  /// keep it open for [idleTimeout] after the last one closes, so that
  /// opening file after file on a server (each file view opens its own
  /// source) does not log in every time. Off by default so that a
  /// background isolate hangs up as soon as it is done; the UI turns it on
  /// for the main isolate.
  static bool shareConnections = false;

  static Duration idleTimeout = const Duration(seconds: 90);

  static const connectTimeout = Duration(seconds: 15);

  static Future<FileSource> open(SftpSource spec) => connect(spec);

  /// [open], typed, for callers that need [homeDirectory] or the key.
  static Future<SftpFileSource> connect(SftpSource spec) async {
    final secret = spec.secret;
    if (secret == null) throw SftpCredentialsRequired(spec.authority);
    final connection = await _Connection.acquire(spec, secret);
    try {
      final writable = await _probeWritable(connection, spec.path);
      return SftpFileSource._(spec, secret, connection, writable);
    } catch (_) {
      connection.release();
      rethrow;
    }
  }

  @override
  final SftpSource spec;

  final SftpSecret _secret;
  _Connection _connection;
  final bool _writable;
  bool _closed = false;

  /// The host key algorithm and fingerprint of the server.
  String get hostKeyType => _connection.hostKeyType;
  String get hostKeySha256 => _connection.fingerprint;

  @override
  bool get writable => _writable;

  String _abs(String relative) =>
      relative.isEmpty ? spec.path : p.posix.join(spec.path, relative);

  /// The user's home folder on the server (where a plain `sftp` session
  /// starts).
  Future<String> homeDirectory() =>
      _run(spec.path, (sftp) => sftp.absolute('.'));

  @override
  String? localPath(String relative) => null;

  @override
  Future<SourceEntry?> stat(String relative) async {
    final abs = _abs(relative);
    final attrs = await _run(abs, (sftp) => _statOrNull(sftp, abs));
    if (attrs == null) return null;
    final name = p.posix.basename(abs);
    return _entry(name.isEmpty ? '/' : name, attrs);
  }

  @override
  Future<List<SourceEntry>> list(String relative) async {
    final abs = _abs(relative);
    final names = await _run(abs, (sftp) => sftp.listdir(abs));
    final out = <SourceEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      final type = name.attr.type ?? _typeFromLongname(name.longname);
      // Links are left out, as the contract asks; so are sockets, pipes
      // and devices, which cannot be compared (and reading a pipe hangs).
      if (type != SftpFileType.directory && type != SftpFileType.regularFile) {
        continue;
      }
      out.add(_entry(name.filename, name.attr, type: type));
    }
    return out;
  }

  @override
  Future<Uint8List> read(String relative) {
    final abs = _abs(relative);
    return _run(abs, (sftp) async {
      final file = await sftp.open(abs);
      try {
        return await file.readBytes();
      } finally {
        await file.close();
      }
    });
  }

  /// Writes to a temporary file next to the target and renames it over the
  /// target, so a dropped connection never leaves a half-written file.
  /// Keeps the target's permissions. Writes in place when the folder does
  /// not allow new files or the target is a symbolic link (which a rename
  /// would replace).
  @override
  Future<void> write(String relative, List<int> bytes) {
    final abs = _abs(relative);
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _run(abs, (sftp) async {
      final dir = p.posix.dirname(abs);
      await _mkdirs(sftp, dir);
      final existing = await _lstatOrNull(sftp, abs);
      if (existing != null && existing.isDirectory) {
        throw SftpOperationFailed('“$abs” is a folder, not a file.');
      }
      final tmp = p.posix.join(dir,
          '.${p.posix.basename(abs)}.deltaview-${_randomTag()}.tmp');

      SftpFile? file;
      if (existing == null || !existing.isSymbolicLink) {
        try {
          file = await sftp.open(tmp,
              mode: SftpFileOpenMode.create |
                  SftpFileOpenMode.write |
                  SftpFileOpenMode.exclusive);
        } on SftpStatusError {
          file = null;
        }
      }
      if (file == null) {
        final target = await sftp.open(abs,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate);
        try {
          await target.writeBytes(data);
        } finally {
          await target.close();
        }
        return;
      }

      try {
        try {
          await file.writeBytes(data);
        } finally {
          await file.close();
        }
        final mode = existing?.mode;
        if (mode != null) {
          try {
            await sftp.setStat(
                tmp, SftpFileAttrs(mode: SftpFileMode.value(mode.value & 0xfff)));
          } on SftpStatusError {
            // Keeping permissions is a courtesy; the content matters.
          }
        }
        try {
          await sftp.rename(tmp, abs);
        } on SftpStatusError {
          // Plain SFTP rename refuses to replace a file; servers without
          // the POSIX rename extension need the target out of the way.
          if (existing == null) rethrow;
          await sftp.remove(abs);
          await sftp.rename(tmp, abs);
        }
      } catch (_) {
        try {
          await sftp.remove(tmp);
        } catch (_) {
          // Leave it; it is hidden and clearly named.
        }
        rethrow;
      }
    });
  }

  @override
  Future<void> delete(String relative) {
    final abs = _abs(relative);
    if (abs == '/' || abs.isEmpty) {
      return Future.error(
          const SftpOperationFailed('DeltaView will not delete “/”.'));
    }
    return _run(abs, (sftp) => _deleteTree(sftp, abs));
  }

  @override
  Future<void> createDirectory(String relative) {
    final abs = _abs(relative);
    return _run(abs, (sftp) => _mkdirs(sftp, abs));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connection.release();
  }

  // ---- helpers ----

  /// Runs [op] on the session, reconnecting once when the connection
  /// dropped (an idle server timing out, a network blip), and turns SFTP
  /// status codes into friendly errors.
  Future<T> _run<T>(String path, Future<T> Function(SftpClient sftp) op) async {
    if (_closed) throw StateError('This SFTP source has been closed.');
    if (_connection.isClosed) await _reconnect();
    try {
      return await op(_connection.sftp);
    } on SftpStatusError catch (e) {
      throw _statusError(e, path);
    } on SftpSourceException {
      rethrow;
    } catch (e) {
      if (!_connection.isClosed) {
        throw SftpConnectionFailed('${spec.host}: $e');
      }
    }
    await _reconnect();
    try {
      return await op(_connection.sftp);
    } on SftpStatusError catch (e) {
      throw _statusError(e, path);
    } on SftpSourceException {
      rethrow;
    } catch (e) {
      throw SftpConnectionFailed(
          'The connection to ${spec.host} was lost and could not be '
          'restored ($e).');
    }
  }

  Future<void> _reconnect() async {
    final old = _connection;
    _connection = await _Connection.acquire(spec, _secret);
    old.release();
  }

  SftpSourceException _statusError(SftpStatusError e, String path) =>
      switch (e.code) {
        SftpStatusCode.noSuchFile =>
          SftpOperationFailed('“$path” does not exist on ${spec.host}.'),
        SftpStatusCode.permissionDenied => SftpPermissionDenied(path),
        SftpStatusCode.opUnsupported => SftpOperationFailed(
            '${spec.host} does not support this operation on “$path”.'),
        _ => SftpOperationFailed(e.message.isEmpty
            ? 'The server could not complete the operation on “$path”.'
            : '“$path”: ${e.message}'),
      };

  static SourceEntry _entry(String name, SftpFileAttrs attrs,
      {SftpFileType? type}) {
    final isDirectory = (type ?? attrs.type) == SftpFileType.directory;
    final mtime = attrs.modifyTime;
    return SourceEntry(
      name: name,
      isDirectory: isDirectory,
      size: isDirectory ? null : attrs.size,
      modified:
          mtime == null ? null : DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
    );
  }

  /// Servers that leave out permissions still send an `ls -l` style line.
  static SftpFileType? _typeFromLongname(String longname) =>
      switch (longname.isEmpty ? '' : longname[0]) {
        'd' => SftpFileType.directory,
        'l' => SftpFileType.symbolicLink,
        '-' => SftpFileType.regularFile,
        _ => null,
      };

  static Future<SftpFileAttrs?> _statOrNull(SftpClient sftp, String path) =>
      _orNull(sftp.stat(path));

  static Future<SftpFileAttrs?> _lstatOrNull(SftpClient sftp, String path) =>
      _orNull(sftp.stat(path, followLink: false));

  static Future<SftpFileAttrs?> _orNull(Future<SftpFileAttrs> stat) async {
    try {
      return await stat;
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  static Future<void> _mkdirs(SftpClient sftp, String abs) async {
    final attrs = await _statOrNull(sftp, abs);
    if (attrs != null) {
      if (attrs.isDirectory) return;
      throw SftpOperationFailed('“$abs” exists and is not a folder.');
    }
    final parent = p.posix.dirname(abs);
    if (parent != abs) await _mkdirs(sftp, parent);
    try {
      await sftp.mkdir(abs);
    } on SftpStatusError {
      // Someone else may have made it in the meantime.
      if ((await _statOrNull(sftp, abs))?.isDirectory ?? false) return;
      rethrow;
    }
  }

  static Future<void> _deleteTree(SftpClient sftp, String abs) async {
    final attrs = await _lstatOrNull(sftp, abs);
    if (attrs == null) return;
    if (!attrs.isDirectory) {
      await sftp.remove(abs);
      return;
    }
    for (final child in await sftp.listdir(abs)) {
      if (child.filename == '.' || child.filename == '..') continue;
      await _deleteTree(sftp, p.posix.join(abs, child.filename));
    }
    await sftp.rmdir(abs);
  }

  /// A cheap guess at whether writes under [path] will be allowed, from its
  /// permission bits and owner. A path that does not exist yet counts as
  /// writable: creating it is tried when asked.
  static Future<bool> _probeWritable(_Connection connection, String path) async {
    final SftpFileAttrs? attrs;
    try {
      attrs = await _statOrNull(connection.sftp, path);
    } on SftpStatusError {
      return false;
    }
    final mode = attrs?.mode;
    if (attrs == null || mode == null) return true;
    final uid = await connection.userId();
    if (uid == 0) return true;
    if (uid != null && attrs.userID == uid) return mode.userWrite;
    return mode.groupWrite || mode.otherWrite || (uid == null && mode.userWrite);
  }

  static final _random = Random();

  static String _randomTag() =>
      _random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
}

// ---------------------------------------------------------------------------
// Connections

/// One SSH connection with its SFTP session, shared by the sources open on
/// the same server (when [SftpFileSource.shareConnections] is on).
class _Connection {
  _Connection._(this._key, this.secret, this.client, this.sftp,
      this.hostKeyType, this.fingerprint) {
    client.done.then((_) => _onClosed(), onError: (_) => _onClosed());
  }

  static final _live = <String, _Connection>{};
  static final _connecting = <String, (SftpSecret, Future<_Connection>)>{};

  final String _key;
  final SftpSecret secret;
  final SSHClient client;
  final SftpClient sftp;
  final String hostKeyType;
  final String fingerprint;

  int _leases = 0;
  Timer? _idle;
  bool _closed = false;
  Future<int?>? _userId;

  bool get isClosed => _closed || client.isClosed;

  static String _keyFor(SftpSource spec) =>
      '${spec.username}@${spec.host.toLowerCase()}:${spec.port}'
      '#${spec.hostKeySha256}';

  static Future<_Connection> acquire(SftpSource spec, SftpSecret secret) async {
    if (!SftpFileSource.shareConnections) {
      return (await _open(spec, secret)).._lease();
    }
    final key = _keyFor(spec);
    final live = _live[key];
    if (live != null && !live.isClosed && _sameSecret(live.secret, secret)) {
      return live.._lease();
    }
    final pending = _connecting[key];
    if (pending != null && _sameSecret(pending.$1, secret)) {
      return (await pending.$2).._lease();
    }
    final future = _open(spec, secret);
    _connecting[key] = (secret, future);
    try {
      final connection = await future;
      final previous = _live[key];
      _live[key] = connection;
      // A connection made with other credentials stays until its sources
      // close.
      if (previous != null && previous._leases == 0) previous._close();
      return connection.._lease();
    } finally {
      if (identical(_connecting[key]?.$2, future)) _connecting.remove(key);
    }
  }

  /// Closes every shared connection now (e.g. when the app quits).
  static Future<void> closeAll() async {
    for (final connection in [..._live.values]) {
      connection._close();
    }
  }

  static bool _sameSecret(SftpSecret a, SftpSecret b) =>
      a.password == b.password &&
      a.privateKeyPem == b.privateKeyPem &&
      a.passphrase == b.passphrase;

  void _lease() {
    _idle?.cancel();
    _idle = null;
    _leases++;
  }

  void release() {
    if (_leases > 0) _leases--;
    if (_leases > 0) return;
    final pooled = SftpFileSource.shareConnections &&
        identical(_live[_key], this) &&
        !isClosed;
    if (pooled) {
      _idle?.cancel();
      _idle = Timer(SftpFileSource.idleTimeout, _close);
    } else {
      _close();
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    if (identical(_live[_key], this)) _live.remove(_key);
    _hangUp(client);
  }

  /// Closes [client] without waiting, ignoring errors from a connection
  /// that is already gone.
  static void _hangUp(SSHClient client) {
    client.close().catchError((_) {});
  }

  void _onClosed() {
    _closed = true;
    _idle?.cancel();
    if (identical(_live[_key], this)) _live.remove(_key);
  }

  /// Our numeric user id on the server, taken from the home folder (which
  /// we own). Null when the server does not say.
  Future<int?> userId() => _userId ??= () async {
        try {
          return (await sftp.stat('.')).userID;
        } catch (_) {
          return null;
        }
      }();

  static Future<_Connection> _open(SftpSource spec, SftpSecret secret) async {
    final identities = await _identities(secret);

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(spec.host, spec.port,
          timeout: SftpFileSource.connectTimeout);
    } on SocketException catch (e) {
      throw SftpHostUnreachable(spec.host, spec.port, _socketReason(e));
    } on TimeoutException {
      throw SftpHostUnreachable(spec.host, spec.port, 'the connection timed out');
    }

    final expected = spec.hostKeySha256 == null
        ? null
        : normalizeSshFingerprint(spec.hostKeySha256!);
    String? presentedType, presented;
    var keyRejected = false;
    var interactiveRounds = 0;
    final password = secret.password;

    final client = SSHClient(
      socket,
      username: spec.username,
      onVerifyHostKey: (type, fingerprint) {
        presentedType = type;
        presented = normalizeSshFingerprint(
            utf8.decode(fingerprint, allowMalformed: true));
        final accepted =
            expected != null && _constantTimeEquals(presented!, expected);
        keyRejected = !accepted;
        return accepted;
      },
      identities: identities,
      onPasswordRequest: password == null ? null : () => password,
      // Servers that only take passwords through PAM ask for them this way.
      onUserInfoRequest: password == null
          ? null
          : (request) {
              if (request.prompts.isEmpty) return const <String>[];
              if (++interactiveRounds > 1) return null;
              if (request.prompts.any((prompt) => prompt.echo)) return null;
              return [for (final _ in request.prompts) password];
            },
      keepAliveInterval: const Duration(seconds: 20),
      handshakeTimeout: const Duration(seconds: 20),
      authTimeout: const Duration(seconds: 30),
    );

    try {
      await client.authenticated;
    } catch (e) {
      _hangUp(client);
      if (keyRejected && presented != null) {
        if (expected == null) {
          throw SftpHostKeyNotTrusted(
              host: spec.host,
              port: spec.port,
              keyType: presentedType!,
              fingerprint: presented!);
        }
        throw SftpHostKeyMismatch(
            host: spec.host,
            port: spec.port,
            keyType: presentedType!,
            fingerprint: presented!,
            expected: expected);
      }
      throw _authError(spec, secret, e);
    }

    try {
      final sftp = await client.sftp();
      await sftp.handshake;
      return _Connection._(_keyFor(spec), secret, client, sftp,
          presentedType ?? '', presented ?? '');
    } catch (e) {
      _hangUp(client);
      throw SftpConnectionFailed(
          '${spec.host} accepted the login but does not offer SFTP.');
    }
  }

  static SftpSourceException _authError(
      SftpSource spec, SftpSecret secret, Object error) {
    if (error is SSHAuthFailError) {
      return SftpAuthFailed(spec.authority,
          usedKey: secret.privateKeyPem != null);
    }
    if (error is SSHAuthAbortError) {
      final reason = error.reason;
      if (reason is SSHSocketError) {
        return SftpConnectionFailed(
            'The connection to ${spec.host} closed during sign-in.');
      }
      if (reason is SSHDisconnectError) {
        return SftpConnectionFailed(
            '${spec.host} hung up during sign-in: ${reason.message}');
      }
      if (reason is SSHHandshakeError || reason is SSHHostkeyError) {
        return SftpConnectionFailed(
            'Could not set up a secure connection with ${spec.host}.');
      }
      if (error.message.contains('timed out')) {
        return SftpConnectionFailed('${spec.host} took too long to sign in.');
      }
      return SftpConnectionFailed(
          'The connection to ${spec.host} closed before sign-in finished.');
    }
    if (error is SSHHandshakeError) {
      return SftpConnectionFailed(
          'Could not set up a secure connection with ${spec.host}: '
          '${error.message}.');
    }
    return SftpConnectionFailed('Could not sign in to ${spec.host}: $error');
  }

  static String _socketReason(SocketException e) {
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (text.contains('refused')) return 'the connection was refused';
    if (text.contains('host lookup') ||
        text.contains('name or service') ||
        text.contains('nodename') ||
        text.contains('no address')) {
      return 'no such host';
    }
    if (text.contains('timed out')) return 'the connection timed out';
    if (text.contains('unreachable')) return 'the network is unreachable';
    final detail = e.osError?.message ?? e.message;
    return detail.isEmpty ? 'the connection failed' : detail;
  }

  static final _decodedKeys = Expando<List<SSHKeyPair>>();

  /// Decodes the private key, off the calling isolate when it is encrypted
  /// (OpenSSH's bcrypt key derivation is slow enough to stall the UI).
  static Future<List<SSHKeyPair>?> _identities(SftpSecret secret) async {
    final pem = secret.privateKeyPem;
    if (pem == null) return null;
    final cached = _decodedKeys[secret];
    if (cached != null) return cached;
    final passphrase =
        (secret.passphrase?.isEmpty ?? true) ? null : secret.passphrase;
    bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } catch (_) {
      throw const SftpPrivateKeyError('That file is not a private key '
          'DeltaView can use (OpenSSH, or PEM RSA or EC).');
    }
    if (encrypted && passphrase == null) {
      throw const SftpPrivateKeyError('This private key is protected by a '
          'passphrase. Enter it to continue.', needsPassphrase: true);
    }
    try {
      final keys = encrypted
          ? await Isolate.run(() => SSHKeyPair.fromPem(pem, passphrase))
          : SSHKeyPair.fromPem(pem);
      return _decodedKeys[secret] = keys;
    } on SSHKeyDecryptError {
      throw const SftpPrivateKeyError(
          'The passphrase for this private key is wrong.',
          needsPassphrase: true);
    } catch (_) {
      throw const SftpPrivateKeyError('That file is not a private key '
          'DeltaView can use (OpenSSH, or PEM RSA or EC).');
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Closes every SFTP connection this isolate keeps open for reuse.
Future<void> closeSharedSftpConnections() => _Connection.closeAll();

/// A SHA-256 host key fingerprint in the form [SftpSource.hostKeySha256]
/// uses: base64 without padding and without the `SHA256:` prefix OpenSSH
/// prints in front of it.
String normalizeSshFingerprint(String fingerprint) {
  var f = fingerprint.trim();
  if (f.toUpperCase().startsWith('SHA256:')) f = f.substring(7);
  while (f.endsWith('=')) {
    f = f.substring(0, f.length - 1);
  }
  return f;
}
