/// The dialogs around SSH host keys: trusting a new server, refusing a
/// changed key, and managing the servers DeltaView trusts.
library;

import 'package:flutter/material.dart';

import '../../compare/sources/sftp_source.dart';
import '../../remote/known_hosts.dart';
import '../../remote/remote_address.dart';
import 'source_ui.dart';

/// Asks whether to trust a server DeltaView has not connected to before.
/// [system] says what OpenSSH's known_hosts thinks of the key.
Future<bool> showTrustHostDialog(
  BuildContext context,
  SftpHostKeyRejected key, {
  SystemKnownHostsMatch system = SystemKnownHostsMatch.none,
}) async {
  final trusted = await showDialog<bool>(
    context: context,
    builder: (context) => _TrustHostDialog(keyInfo: key, system: system),
  );
  return trusted ?? false;
}

class _TrustHostDialog extends StatelessWidget {
  const _TrustHostDialog({required this.keyInfo, required this.system});

  final SftpHostKeyRejected keyInfo;
  final SystemKnownHostsMatch system;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final address = displayAddress(keyInfo.host, keyInfo.port);
    final revoked = system == SystemKnownHostsMatch.revoked;
    return AlertDialog(
      icon: Icon(Icons.verified_user_outlined, color: scheme.primary),
      title: const Text('Trust this host?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DeltaView has not connected to $address before. Make sure '
                'the fingerprint below is the server’s, for example by '
                'asking its administrator or running “ssh-keygen -lf” on '
                'its host key. Nothing has been sent to the server yet.'),
            const SizedBox(height: 16),
            FingerprintView(
              label: '${keyTypeLabel(keyInfo.keyType)} key',
              fingerprint: keyInfo.fingerprint,
            ),
            if (system != SystemKnownHostsMatch.none) ...[
              const SizedBox(height: 12),
              _SystemNote(system: system, keyType: keyInfo.keyType),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: revoked ? null : () => Navigator.pop(context, true),
          child: const Text('Trust and connect'),
        ),
      ],
    );
  }
}

class _SystemNote extends StatelessWidget {
  const _SystemNote({required this.system, required this.keyType});

  final SystemKnownHostsMatch system;
  final String keyType;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (icon, color, text) = switch (system) {
      SystemKnownHostsMatch.matches => (
          Icons.check_circle_outline,
          isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
          'Your SSH client already trusts this key for this host '
              '(~/.ssh/known_hosts).',
        ),
      SystemKnownHostsMatch.differs => (
          Icons.warning_amber_rounded,
          isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
          '~/.ssh/known_hosts lists a different ${keyTypeLabel(keyType)} '
              'key for this host. Be careful: confirm the fingerprint '
              'before trusting it.',
        ),
      SystemKnownHostsMatch.revoked => (
          Icons.gpp_bad_outlined,
          scheme.error,
          'This key is marked as revoked in ~/.ssh/known_hosts. DeltaView '
              'will not trust it.',
        ),
      SystemKnownHostsMatch.none => (Icons.info_outline, scheme.primary, ''),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// Warns that a server's key changed, and refuses the connection. The
/// only way forward is removing the old key in the known hosts manager,
/// deliberately. Returns true when the user did that.
Future<bool> showHostKeyChangedDialog(
  BuildContext context,
  SftpHostKeyMismatch mismatch,
  KnownHostsStore store,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) =>
        _HostKeyChangedDialog(mismatch: mismatch, store: store),
  );
  final recorded = store.lookup(mismatch.host, mismatch.port);
  return recorded == null || recorded.fingerprint != mismatch.expected;
}

class _HostKeyChangedDialog extends StatelessWidget {
  const _HostKeyChangedDialog({required this.mismatch, required this.store});

  final SftpHostKeyMismatch mismatch;
  final KnownHostsStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final address = displayAddress(mismatch.host, mismatch.port);
    final known = store.lookup(mismatch.host, mismatch.port);
    return AlertDialog(
      icon: Icon(Icons.gpp_bad_outlined, color: scheme.error, size: 36),
      title: Text('The identity of $address has changed'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The server presented a different host key from the one you '
                'trusted. DeltaView refused to connect and sent nothing: '
                'no password, no key.',
                style: TextStyle(
                    color: scheme.error, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                  'This happens when a server is reinstalled or its keys are '
                  'replaced, but it can also mean that someone is '
                  'intercepting the connection. Do not continue unless the '
                  'server’s administrator confirms the new fingerprint.'),
              const SizedBox(height: 16),
              if (known != null) ...[
                FingerprintView(
                  label: 'Trusted ${keyTypeLabel(known.keyType)} key',
                  fingerprint: known.fingerprint,
                ),
                const SizedBox(height: 8),
              ],
              FingerprintView(
                label: 'Presented now (${keyTypeLabel(mismatch.keyType)})',
                fingerprint: mismatch.fingerprint,
                emphasis: scheme.error,
              ),
              const SizedBox(height: 14),
              Text(
                'If the change is legitimate, remove the old key under '
                'Known hosts and connect again; you will be asked to trust '
                'the new one.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await showKnownHostsDialog(context,
                highlightHost: mismatch.host, highlightPort: mismatch.port);
            if (!context.mounted) return;
            final current = store.lookup(mismatch.host, mismatch.port);
            if (current == null || current.fingerprint != mismatch.expected) {
              Navigator.pop(context);
            }
          },
          child: const Text('Known hosts…'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Don’t connect'),
        ),
      ],
    );
  }
}

/// Lists the servers DeltaView trusts, and lets the user remove them.
Future<void> showKnownHostsDialog(
  BuildContext context, {
  String? highlightHost,
  int? highlightPort,
}) async {
  final store = await KnownHostsStore.shared();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _KnownHostsDialog(
      store: store,
      highlightHost:
          highlightHost == null ? null : normalizeHost(highlightHost),
      highlightPort: highlightPort,
    ),
  );
}

class _KnownHostsDialog extends StatelessWidget {
  const _KnownHostsDialog({
    required this.store,
    this.highlightHost,
    this.highlightPort,
  });

  final KnownHostsStore store;
  final String? highlightHost;
  final int? highlightPort;

  Future<void> _remove(BuildContext context, KnownHost host) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove the key for ${host.address}?'),
        content: const Text('The next connection to this server will ask '
            'you to confirm its key again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure == true) await store.remove(host.host, host.port);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Known hosts'),
      content: SizedBox(
        width: 560,
        height: 380,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final hosts = [...store.hosts]
              ..sort((a, b) => a.address.compareTo(b.address));
            if (hosts.isEmpty) {
              return Center(
                child: Text(
                  'DeltaView does not trust any servers yet. It asks the '
                  'first time you connect to one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              );
            }
            return ListView.separated(
              itemCount: hosts.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Text(
                    'Servers whose identity you confirmed. DeltaView refuses '
                    'to connect when one of them presents a different key.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  );
                }
                final host = hosts[i - 1];
                final highlighted =
                    host.host == highlightHost && host.port == highlightPort;
                return Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  decoration: BoxDecoration(
                    color: highlighted
                        ? scheme.errorContainer.withValues(alpha: 0.5)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: highlighted
                        ? Border.all(color: scheme.error.withValues(alpha: 0.6))
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(host.address,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            SelectableText(
                              '${keyTypeLabel(host.keyType)}  '
                              'SHA256:${host.fingerprint}',
                              style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant),
                            ),
                            Text('Trusted ${formatShortDate(host.added)}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove this key',
                        onPressed: () => _remove(context, host),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
