/// Passwords and keys entered during this run of the app, so that opening
/// another comparison on the same server (or restoring one) does not ask
/// again. Memory only: nothing here is ever written to disk.
library;

import '../compare/sources/source_spec.dart';
import 'remote_address.dart';

class RemoteCredentialCache {
  RemoteCredentialCache._();

  static final _secrets = <String, SftpSecret>{};

  static String _key(SftpSource source) => accountKey(
      username: source.username, host: source.host, port: source.port);

  static SftpSecret? lookup(SftpSource source) => _secrets[_key(source)];

  static void remember(SftpSource source, SftpSecret secret) =>
      _secrets[_key(source)] = secret;

  /// Drops the secret for [source]'s account, e.g. after the server
  /// refused it.
  static void forget(SftpSource source) => _secrets.remove(_key(source));

  static void clear() => _secrets.clear();
}
