/// Connecting to an SFTP server from the UI: the host key check against
/// DeltaView's known hosts, with the user deciding about new keys.
library;

import 'package:flutter/widgets.dart';

import '../../compare/sources/sftp_source.dart';
import '../../compare/sources/source_spec.dart';
import '../../remote/known_hosts.dart';
import 'host_key_dialogs.dart';

/// Wraps one connection attempt, e.g. in a progress dialog. Returns null
/// when the user cancelled it.
typedef ConnectAttempt = Future<SftpFileSource?> Function(
    Future<SftpFileSource> Function() connect);

/// Connects to [spec] (which carries a secret) trusting only the key
/// DeltaView's known hosts records for the server, whatever key [spec]
/// itself remembers. A server with no recorded key is shown to the user
/// before anything else is sent; a changed key is refused until the user
/// removes the old one on purpose.
///
/// Returns null when the user declined or cancelled. Other failures throw
/// [SftpSourceException].
Future<SftpFileSource?> connectWithVerifiedHostKey(
  BuildContext context,
  SftpSource spec, {
  ConnectAttempt? attempt,
}) async {
  final store = await KnownHostsStore.shared();
  final run = attempt ?? (connect) => connect();
  while (true) {
    if (!context.mounted) return null;
    final known = store.lookup(spec.host, spec.port);
    final pinned = SftpSource(
      host: spec.host,
      port: spec.port,
      username: spec.username,
      path: spec.path,
      hostKeySha256: known?.fingerprint,
      secret: spec.secret,
    );
    try {
      return await run(() => SftpFileSource.connect(pinned));
    } on SftpHostKeyNotTrusted catch (e) {
      final system = await checkSystemKnownHosts(
          host: e.host,
          port: e.port,
          keyType: e.keyType,
          fingerprint: e.fingerprint);
      if (!context.mounted) return null;
      if (!await showTrustHostDialog(context, e, system: system)) return null;
      try {
        await store.trust(
            host: e.host,
            port: e.port,
            keyType: e.keyType,
            fingerprint: e.fingerprint);
      } on StateError {
        // Another key was recorded meanwhile; the next round checks it.
      }
      // Connect again, now requiring exactly the key the user saw.
    } on SftpHostKeyMismatch catch (e) {
      if (!context.mounted) return null;
      if (!await showHostKeyChangedDialog(context, e, store)) return null;
      // The old key was removed: the next round asks about the new one.
    }
  }
}
