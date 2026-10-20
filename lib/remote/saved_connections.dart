/// Servers the user connected to before, offered again in the connect
/// dialog. Stored as JSON in the app support directory, and never with a
/// password or passphrase: only how to sign in (and which key file).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'json_file.dart';
import 'remote_address.dart';

enum RemoteAuthMethod { password, privateKey }

class SavedConnection {
  const SavedConnection({
    required this.host,
    this.port = 22,
    required this.username,
    this.auth = RemoteAuthMethod.password,
    this.keyPath,
    this.lastPath,
    this.lastUsed,
  });

  final String host;
  final int port;
  final String username;
  final RemoteAuthMethod auth;

  /// The private key file, for [RemoteAuthMethod.privateKey].
  final String? keyPath;

  /// The folder last opened on this server, to start browsing there.
  final String? lastPath;
  final DateTime? lastUsed;

  /// One saved connection per account: `user@host:port`.
  String get id => accountKey(username: username, host: host, port: port);

  /// `user@host` or `user@host:port`.
  String get label => '$username@${displayAddress(host, port)}';

  SavedConnection copyWith({String? lastPath, DateTime? lastUsed}) =>
      SavedConnection(
        host: host,
        port: port,
        username: username,
        auth: auth,
        keyPath: keyPath,
        lastPath: lastPath ?? this.lastPath,
        lastUsed: lastUsed ?? this.lastUsed,
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (keyPath != null) 'keyPath': keyPath,
        if (lastPath != null) 'lastPath': lastPath,
        if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  static SavedConnection? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'], username = json['username'];
    if (host is! String || host.isEmpty || username is! String) return null;
    return SavedConnection(
      host: host,
      port: json['port'] is int ? json['port'] as int : 22,
      username: username,
      auth: RemoteAuthMethod.values.asNameMap()[json['auth']] ??
          RemoteAuthMethod.password,
      keyPath: json['keyPath'] as String?,
      lastPath: json['lastPath'] as String?,
      lastUsed: DateTime.tryParse('${json['lastUsed']}'),
    );
  }
}

class SavedConnectionsStore extends ChangeNotifier {
  /// A store backed by [file], or held in memory only when it is null.
  SavedConnectionsStore({this.file});

  final File? file;
  final List<SavedConnection> _connections = [];

  static const maxConnections = 50;

  static Future<SavedConnectionsStore>? _shared;

  /// The app's store, loaded on first use.
  static Future<SavedConnectionsStore> shared() => _shared ??= () async {
        File? file;
        try {
          file = await appSupportFile('remote_connections.json');
        } catch (e) {
          debugPrint('Saved connections kept in memory only: $e');
        }
        final store = SavedConnectionsStore(file: file);
        await store.load();
        return store;
      }();

  Future<void> load() async {
    final file = this.file;
    if (file == null) return;
    final json = await readJsonFile(file);
    final list = json is Map ? json['connections'] : null;
    _connections
      ..clear()
      ..addAll([
        if (list is List)
          for (final c in list) ?SavedConnection.fromJson(c),
      ]);
    notifyListeners();
  }

  /// Most recently used first.
  List<SavedConnection> get connections => List.unmodifiable(_connections);

  SavedConnection? find(
      {required String username, required String host, required int port}) {
    final id = accountKey(username: username, host: host, port: port);
    return _connections.where((c) => c.id == id).firstOrNull;
  }

  /// Adds [connection], or replaces the one for the same account, and
  /// moves it to the top.
  Future<void> remember(SavedConnection connection) async {
    _connections
      ..removeWhere((c) => c.id == connection.id)
      ..insert(0, connection);
    if (_connections.length > maxConnections) {
      _connections.removeRange(maxConnections, _connections.length);
    }
    await _save();
  }

  Future<void> forget(String id) async {
    final before = _connections.length;
    _connections.removeWhere((c) => c.id == id);
    if (_connections.length != before) await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    final file = this.file;
    if (file == null) return;
    await writeJsonFile(file, {
      'version': 1,
      'connections': [for (final c in _connections) c.toJson()],
    });
  }
}
