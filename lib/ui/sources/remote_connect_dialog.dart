/// The "Connect to server" dialog: saved connections on the left, a form
/// on the right. Also used, with the account fixed, to sign in again to a
/// server a restored comparison points at.
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../compare/sources/sftp_source.dart';
import '../../compare/sources/source_spec.dart';
import '../../remote/remote_address.dart';
import '../../remote/saved_connections.dart';
import 'host_key_dialogs.dart';
import 'remote_session.dart';
import 'source_ui.dart';

/// A signed-in, host-verified connection, and the secret that opened it.
class RemoteConnection {
  const RemoteConnection(this.source, this.secret);

  /// Rooted at the path the dialog was opened for (`/` for a new
  /// connection). The caller closes it.
  final SftpFileSource source;
  final SftpSecret secret;
}

/// Asks for a server and credentials and connects. With [account], only
/// the credentials are asked for (the server and user are fixed), and
/// [initialError] can say why (e.g. the remembered password was refused).
Future<RemoteConnection?> showRemoteConnectDialog(
  BuildContext context, {
  SftpSource? account,
  String? initialError,
}) async {
  final saved = await SavedConnectionsStore.shared();
  if (!context.mounted) return null;
  return showDialog<RemoteConnection>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RemoteConnectDialog(
      saved: saved,
      account: account,
      initialError: initialError,
    ),
  );
}

class RemoteConnectDialog extends StatefulWidget {
  const RemoteConnectDialog({
    super.key,
    required this.saved,
    this.account,
    this.initialError,
  });

  final SavedConnectionsStore saved;
  final SftpSource? account;
  final String? initialError;

  @override
  State<RemoteConnectDialog> createState() => _RemoteConnectDialogState();
}

class _RemoteConnectDialogState extends State<RemoteConnectDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  final _passwordFocus = FocusNode();
  final _passphraseFocus = FocusNode();
  final _hostFocus = FocusNode();

  RemoteAuthMethod _auth = RemoteAuthMethod.password;
  String? _keyPath;
  bool _keyEncrypted = false;
  bool _save = true;
  bool _showSecret = false;
  bool _busy = false;
  late String? _error = widget.initialError;

  bool get _fixed => widget.account != null;

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    if (account != null) {
      _host.text = account.host;
      _port.text = '${account.port}';
      _user.text = account.username;
      final saved = widget.saved.find(
          username: account.username, host: account.host, port: account.port);
      if (saved != null) _fill(saved, focus: false);
    } else if (Platform.environment['USER'] case final user?) {
      _user.text = user;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_fixed) {
        (_auth == RemoteAuthMethod.password ? _passwordFocus : _passphraseFocus)
            .requestFocus();
      } else {
        _hostFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, _passphrase]) {
      c.dispose();
    }
    _passwordFocus.dispose();
    _passphraseFocus.dispose();
    _hostFocus.dispose();
    super.dispose();
  }

  void _fill(SavedConnection c, {bool focus = true}) {
    setState(() {
      _host.text = c.host;
      _port.text = '${c.port}';
      _user.text = c.username;
      _auth = c.auth;
      _password.clear();
      _passphrase.clear();
      _keyPath = c.keyPath;
      _error = null;
    });
    if (c.auth == RemoteAuthMethod.privateKey && c.keyPath != null) {
      _inspectKey(c.keyPath!, quiet: true);
    }
    if (focus) {
      (c.auth == RemoteAuthMethod.password ? _passwordFocus : _passphraseFocus)
          .requestFocus();
    }
  }

  Future<void> _chooseKey() async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final sshDir = home == null ? null : p.join(home, '.ssh');
    final file = await openFile(
      initialDirectory:
          sshDir != null && Directory(sshDir).existsSync() ? sshDir : null,
      confirmButtonText: 'Use key',
    );
    if (file == null || !mounted) return;
    setState(() {
      _keyPath = file.path;
      _error = null;
    });
    await _inspectKey(file.path);
  }

  /// Reads the key to say early whether it needs a passphrase, or is not a
  /// private key at all.
  Future<void> _inspectKey(String path, {bool quiet = false}) async {
    String? problem;
    var encrypted = false;
    try {
      final text = await File(path).readAsString();
      if (text.trimLeft().startsWith('ssh-') ||
          text.trimLeft().startsWith('ecdsa-')) {
        problem = 'That is a public key. Choose the private key: the same '
            'name without “.pub”.';
      } else {
        encrypted = SSHKeyPair.isEncryptedPem(text);
      }
    } on FileSystemException catch (e) {
      problem = 'Could not read the key file: ${e.osError?.message ?? e.message}.';
    } catch (_) {
      problem = 'That file is not a private key DeltaView can use '
          '(OpenSSH, or PEM RSA or EC).';
    }
    if (!mounted) return;
    setState(() {
      _keyEncrypted = encrypted;
      if (!quiet || problem != null) _error = problem;
    });
    if (encrypted) _passphraseFocus.requestFocus();
  }

  Future<void> _connect() async {
    if (_busy) return;
    if (!_fixed) _splitPastedAddress();
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());
    String? problem;
    if (host.isEmpty) {
      problem = 'Enter the server’s host name or address.';
    } else if (port == null || port < 1 || port > 65535) {
      problem = 'The port must be a number from 1 to 65535.';
    } else if (user.isEmpty) {
      problem = 'Enter the user name to sign in as.';
    } else if (_auth == RemoteAuthMethod.privateKey && _keyPath == null) {
      problem = 'Choose your private key file.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    final SftpSecret secret;
    if (_auth == RemoteAuthMethod.password) {
      secret = SftpSecret(password: _password.text);
    } else {
      try {
        secret = SftpSecret(
          privateKeyPem: await File(_keyPath!).readAsString(),
          passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
        );
      } on FileSystemException catch (e) {
        setState(() => _error = 'Could not read the key file: '
            '${e.osError?.message ?? e.message}.');
        return;
      }
    }

    final spec = SftpSource(
      host: host,
      port: port!,
      username: user,
      path: widget.account?.path ?? '/',
      secret: secret,
    );
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await connectWithVerifiedHostKey(context, spec);
      if (!mounted) {
        await source?.close();
        return;
      }
      if (source == null) {
        _fail('Not connected: the server’s identity was not confirmed.');
        return;
      }
      if (_save && !_fixed) {
        final previous =
            widget.saved.find(username: user, host: host, port: port);
        await widget.saved.remember(SavedConnection(
          host: host,
          port: port,
          username: user,
          auth: _auth,
          keyPath: _auth == RemoteAuthMethod.privateKey ? _keyPath : null,
          lastPath: previous?.lastPath,
          lastUsed: DateTime.now(),
        ));
      }
      if (!mounted) {
        await source.close();
        return;
      }
      Navigator.pop(context, RemoteConnection(source, secret));
    } on SftpPrivateKeyError catch (e) {
      _fail(e.message);
      if (e.needsPassphrase) {
        setState(() => _keyEncrypted = true);
        _passphraseFocus.requestFocus();
      }
    } on SftpAuthFailed catch (e) {
      _fail(e.message);
      (_auth == RemoteAuthMethod.password ? _passwordFocus : _passphraseFocus)
          .requestFocus();
    } on SftpSourceException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('Could not connect: $e');
    }
  }

  /// Accepts `user@host:port` (or an ssh:// URL) typed into the host field
  /// by spreading it over the user and port fields.
  void _splitPastedAddress() {
    final parsed = parseServerAddress(_host.text);
    if (parsed.host.isEmpty) return;
    _host.text = parsed.host;
    if (parsed.username case final user? when user.isNotEmpty) {
      _user.text = user;
    }
    if (parsed.port case final port?) _port.text = '$port';
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.saved,
      builder: (context, _) {
        final saved = widget.saved.connections;
        if (_fixed || saved.isEmpty) {
          return Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: _form(context),
            ),
          );
        }
        final scheme = Theme.of(context).colorScheme;
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 780,
            height: 560,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 260, child: _savedList(context, saved)),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(child: _form(context, fill: true)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// [fill]: the dialog has a fixed height (next to the saved list), so
  /// the form keeps its buttons at the bottom.
  Widget _form(BuildContext context, {bool fill = false}) {
    final scheme = Theme.of(context).colorScheme;
    final account = widget.account;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.dns_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  account == null
                      ? 'Connect to a server'
                      : 'Sign in to ${account.authority}',
                  style: Theme.of(context).textTheme.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            account == null
                ? 'Compare files over SFTP (SSH).'
                : 'To open ${account.description}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Flexible(
            fit: fill ? FlexFit.tight : FlexFit.loose,
            child: SingleChildScrollView(
              // Room for the outlined fields' floating labels.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_fixed) ..._serverFields(),
                  _authFields(context),
                  if (!_fixed) ...[
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      value: _save,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _save = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('Save this connection'),
                      subtitle: const Text(
                          'Passwords and passphrases are never saved.'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Outside the scrolling part, so it is always in view.
          if (_error != null) ...[
            const SizedBox(height: 10),
            ErrorBanner(_error!),
          ],
          const SizedBox(height: 18),
          _actions(context),
        ],
      ),
    );
  }

  List<Widget> _serverFields() => [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _host,
                focusNode: _hostFocus,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'server.example.com or user@server:2222',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _connect(),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 92,
              child: TextField(
                controller: _port,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _connect(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _user,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'User name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 14),
      ];

  Widget _authFields(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyName = _keyPath == null ? null : p.basename(_keyPath!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<RemoteAuthMethod>(
          segments: const [
            ButtonSegment(
              value: RemoteAuthMethod.password,
              label: Text('Password'),
              icon: Icon(Icons.password),
            ),
            ButtonSegment(
              value: RemoteAuthMethod.privateKey,
              label: Text('Private key'),
              icon: Icon(Icons.key_outlined),
            ),
          ],
          selected: {_auth},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                    _auth = s.first;
                    _error = null;
                  }),
        ),
        const SizedBox(height: 12),
        if (_auth == RemoteAuthMethod.password)
          _secretField(_password, _passwordFocus, 'Password')
        else ...[
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Key file',
                    border: const OutlineInputBorder(),
                    enabled: !_busy,
                  ),
                  child: Text(
                    keyName ?? 'None chosen',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: keyName == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _busy ? null : _chooseKey,
                child: const Text('Choose…'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _secretField(
            _passphrase,
            _passphraseFocus,
            _keyEncrypted ? 'Passphrase' : 'Passphrase (if the key has one)',
          ),
        ],
      ],
    );
  }

  Widget _secretField(
      TextEditingController controller, FocusNode focus, String label) {
    return TextField(
      controller: controller,
      focusNode: focus,
      enabled: !_busy,
      obscureText: !_showSecret,
      enableSuggestions: false,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _showSecret ? 'Hide' : 'Show',
          onPressed: () => setState(() => _showSecret = !_showSecret),
          icon: Icon(_showSecret
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined),
        ),
      ),
      onSubmitted: (_) => _connect(),
    );
  }

  Widget _actions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy ? null : () => showKnownHostsDialog(context),
              icon: const Icon(Icons.verified_user_outlined, size: 18),
              label: const Text('Known hosts…',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2))
              : Text(_fixed ? 'Sign in' : 'Connect'),
        ),
      ],
    );
  }

  Widget _savedList(BuildContext context, List<SavedConnection> saved) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
            child: Text('Saved',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: saved.length,
              itemBuilder: (context, i) {
                final c = saved[i];
                final selected = normalizeHost(_host.text) ==
                        normalizeHost(c.host) &&
                    _port.text.trim() == '${c.port}' &&
                    _user.text.trim() == c.username;
                final how = c.auth == RemoteAuthMethod.privateKey
                    ? (c.keyPath == null ? 'key' : p.basename(c.keyPath!))
                    : 'password';
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedTileColor:
                      scheme.primaryContainer.withValues(alpha: 0.6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsetsDirectional.only(
                      start: 12, end: 4),
                  minLeadingWidth: 20,
                  leading: Icon(
                      c.auth == RemoteAuthMethod.privateKey
                          ? Icons.key_outlined
                          : Icons.dns_outlined,
                      size: 20),
                  title: Text(displayAddress(c.host, c.port),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${c.username} · $how',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: _busy ? null : () => _fill(c),
                  trailing: IconButton(
                    tooltip: 'Forget this connection',
                    iconSize: 18,
                    onPressed:
                        _busy ? null : () => widget.saved.forget(c.id),
                    icon: const Icon(Icons.close),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
