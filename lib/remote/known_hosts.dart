/// The SSH servers whose identity the user confirmed, DeltaView's own
/// equivalent of `~/.ssh/known_hosts`, plus a read-only look at OpenSSH's
/// file to tell the user whether a new key is one their ssh already knows.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;

import 'json_file.dart';
import 'remote_address.dart';

/// The SHA-256 fingerprint of an SSH public key blob (the base64 field of
/// a `.pub` or `known_hosts` line, decoded), as `ssh-keygen -l` prints it
/// after `SHA256:`: base64 without padding.
String openSshFingerprint(List<int> keyBlob) =>
    base64.encode(sha256.convert(keyBlob).bytes).replaceAll('=', '');

/// A short, familiar name for a host key algorithm, e.g. `ED25519`.
String keyTypeLabel(String keyType) {
  final t = keyType.toLowerCase();
  if (t.contains('ed25519')) return 'ED25519';
  if (t.contains('ed448')) return 'ED448';
  if (t.contains('rsa')) return 'RSA';
  if (t.startsWith('ecdsa-sha2-nistp')) {
    return 'ECDSA P-${t.substring('ecdsa-sha2-nistp'.length)}';
  }
  if (t.contains('dss')) return 'DSA';
  return keyType;
}

/// Key algorithms that use the same key: an RSA host key signs as
/// `rsa-sha2-512`, `rsa-sha2-256` or `ssh-rsa`, and is stored as `ssh-rsa`.
String _keyFamily(String keyType) =>
    keyType.startsWith('rsa-sha2-') ? 'ssh-rsa' : keyType;

class KnownHost {
  const KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.added,
  });

  /// Normalized (see [normalizeHost]).
  final String host;
  final int port;
  final String keyType;

  /// Base64 SHA-256, no padding, no `SHA256:` prefix.
  final String fingerprint;
  final DateTime added;

  String get address => displayAddress(host, port);

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'keyType': keyType,
        'sha256': fingerprint,
        'added': added.toIso8601String(),
      };

  static KnownHost? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'], fingerprint = json['sha256'];
    if (host is! String || fingerprint is! String || fingerprint.isEmpty) {
      return null;
    }
    return KnownHost(
      host: normalizeHost(host),
      port: json['port'] is int ? json['port'] as int : 22,
      keyType: json['keyType'] is String ? json['keyType'] as String : '',
      fingerprint: fingerprint,
      added: DateTime.tryParse('${json['added']}') ?? DateTime.now(),
    );
  }
}

enum HostKeyVerdict {
  /// The server presented the key the user accepted.
  trusted,

  /// No key is on record for this server.
  unknown,

  /// A different key is on record: the server was re-keyed, or someone is
  /// in the middle.
  changed,
}

/// DeltaView's known hosts: one confirmed key per `host:port`, in a JSON
/// file in the app support directory. A changed key never replaces the
/// recorded one silently; the user has to remove the old entry first.
class KnownHostsStore extends ChangeNotifier {
  /// A store backed by [file], or held in memory only when it is null.
  KnownHostsStore({this.file});

  final File? file;
  final List<KnownHost> _hosts = [];

  static Future<KnownHostsStore>? _shared;

  /// The app's store, loaded on first use.
  static Future<KnownHostsStore> shared() => _shared ??= () async {
        File? file;
        try {
          file = await appSupportFile('known_hosts.json');
        } catch (e) {
          debugPrint('Known hosts kept in memory only: $e');
        }
        final store = KnownHostsStore(file: file);
        await store.load();
        return store;
      }();

  Future<void> load() async {
    final file = this.file;
    if (file == null) return;
    final json = await readJsonFile(file);
    final list = json is Map ? json['hosts'] : null;
    _hosts
      ..clear()
      ..addAll([
        if (list is List)
          for (final h in list) ?KnownHost.fromJson(h),
      ]);
    notifyListeners();
  }

  List<KnownHost> get hosts => List.unmodifiable(_hosts);

  KnownHost? lookup(String host, int port) {
    final h = normalizeHost(host);
    return _hosts.where((k) => k.host == h && k.port == port).firstOrNull;
  }

  HostKeyVerdict verdict(String host, int port, String fingerprint) {
    final known = lookup(host, port);
    if (known == null) return HostKeyVerdict.unknown;
    return known.fingerprint == fingerprint
        ? HostKeyVerdict.trusted
        : HostKeyVerdict.changed;
  }

  /// Records that the user confirmed [fingerprint] for [host]:[port].
  /// Throws [StateError] when a different key is already recorded: that
  /// one has to be [remove]d first, deliberately.
  Future<void> trust({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    final existing = lookup(host, port);
    if (existing != null) {
      if (existing.fingerprint == fingerprint) return;
      throw StateError('A different key is recorded for '
          '${existing.address}. Remove it before trusting a new one.');
    }
    _hosts.add(KnownHost(
      host: normalizeHost(host),
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      added: DateTime.now(),
    ));
    await _save();
  }

  Future<void> remove(String host, int port) async {
    final h = normalizeHost(host);
    final before = _hosts.length;
    _hosts.removeWhere((k) => k.host == h && k.port == port);
    if (_hosts.length != before) await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    final file = this.file;
    if (file == null) return;
    await writeJsonFile(file, {
      'version': 1,
      'hosts': [for (final h in _hosts) h.toJson()],
    });
  }
}

/// What OpenSSH's `known_hosts` says about a key DeltaView has not seen
/// before.
enum SystemKnownHostsMatch {
  /// Your ssh already trusts this exact key for this host.
  matches,

  /// Your ssh knows a different key of the same type for this host.
  differs,

  /// The key is marked `@revoked`.
  revoked,

  /// Nothing to say: no entry, only hashed entries, or no file.
  none,
}

/// Looks [host]:[port] up in OpenSSH's known_hosts ([file], or
/// `~/.ssh/known_hosts`). Plain host names only: hashed entries are
/// skipped, as are wildcard patterns.
Future<SystemKnownHostsMatch> checkSystemKnownHosts({
  required String host,
  required int port,
  required String keyType,
  required String fingerprint,
  File? file,
}) async {
  file ??= _defaultKnownHostsFile();
  if (file == null) return SystemKnownHostsMatch.none;
  final String text;
  try {
    if (!await file.exists()) return SystemKnownHostsMatch.none;
    text = await file.readAsString();
  } catch (_) {
    return SystemKnownHostsMatch.none;
  }
  return matchKnownHostsText(text,
      host: host, port: port, keyType: keyType, fingerprint: fingerprint);
}

/// [checkSystemKnownHosts] on the text of a known_hosts file.
SystemKnownHostsMatch matchKnownHostsText(
  String text, {
  required String host,
  required int port,
  required String keyType,
  required String fingerprint,
}) {
  final wantedHost = normalizeHost(host);
  final family = _keyFamily(keyType);
  var differs = false;
  var matches = false;

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    var fields = line.split(RegExp(r'\s+'));
    String? marker;
    if (fields.first.startsWith('@')) {
      marker = fields.first;
      fields = fields.sublist(1);
    }
    if (fields.length < 3 || marker == '@cert-authority') continue;
    if (!_hostsFieldMatches(fields[0], wantedHost, port)) continue;

    final String lineFingerprint;
    try {
      lineFingerprint = openSshFingerprint(base64.decode(fields[2]));
    } on FormatException {
      continue;
    }
    if (marker == '@revoked') {
      if (lineFingerprint == fingerprint) return SystemKnownHostsMatch.revoked;
      continue;
    }
    if (lineFingerprint == fingerprint) {
      matches = true;
    } else if (_keyFamily(fields[1]) == family) {
      differs = true;
    }
  }
  if (matches) return SystemKnownHostsMatch.matches;
  if (differs) return SystemKnownHostsMatch.differs;
  return SystemKnownHostsMatch.none;
}

bool _hostsFieldMatches(String field, String host, int port) {
  if (field.startsWith('|')) return false; // hashed
  for (final pattern in field.split(',')) {
    if (pattern.isEmpty ||
        pattern.startsWith('!') ||
        pattern.contains('*') ||
        pattern.contains('?')) {
      continue;
    }
    var name = pattern;
    var patternPort = 22;
    final bracketed = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(pattern);
    if (bracketed != null) {
      name = bracketed.group(1)!;
      patternPort = int.parse(bracketed.group(2)!);
    }
    if (patternPort == port && normalizeHost(name) == host) return true;
  }
  return false;
}

File? _defaultKnownHostsFile() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return File(p.join(home, '.ssh', 'known_hosts'));
}
