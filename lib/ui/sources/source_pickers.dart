/// Pickers for the non-local sides of a comparison, used by the home
/// screen's Left / Right cards.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../compare/comparison.dart';
import '../../compare/sources/archive_source.dart';
import '../../compare/sources/file_source.dart';
import '../../compare/sources/sftp_source.dart';
import '../../remote/credential_cache.dart';
import '../../remote/remote_address.dart';
import '../../remote/saved_connections.dart';
import 'remote_connect_dialog.dart';
import 'remote_session.dart';
import 'source_browser_dialog.dart';
import 'source_ui.dart';

export 'host_key_dialogs.dart' show showKnownHostsDialog;

/// Whether archive and remote sources can be picked yet. The home screen
/// hides the "Archive…" and "Remote…" choices while this is false.
const archivePickerAvailable = true;
const remotePickerAvailable = true;

/// Every view opens its own source on the main isolate, so keep archives
/// indexed and SFTP connections open between them for a while. (Background
/// isolates keep the defaults and let go as soon as they finish.)
void _reuseSourcesOnThisIsolate() {
  ArchiveFileSource.keepRecentArchivesOpen = true;
  SftpFileSource.shareConnections = true;
}

const _archiveTypes = XTypeGroup(
  label: 'Archives',
  extensions: [
    'zip', 'jar', 'tar', 'gz', 'tgz', 'bz2', 'tbz2', 'tbz', 'xz', 'txz', //
    'zst', 'tzst',
  ],
);
const _allFiles = XTypeGroup(label: 'All files');

/// Lets the user choose an archive (and optionally a folder inside it).
/// Returns null when cancelled.
Future<ArchiveSource?> pickArchiveSource(BuildContext context) async {
  _reuseSourcesOnThisIsolate();
  final file = await openFile(
    acceptedTypeGroups: const [_archiveTypes, _allFiles],
    confirmButtonText: 'Open archive',
  );
  if (file == null || !context.mounted) return null;
  final archivePath = file.path;
  final name = p.basename(archivePath);

  final FileSource? source;
  try {
    source = await runWithProgress(
      context,
      message: 'Reading $name…',
      task: () => FileSource.open(ArchiveSource(archivePath)),
      discard: (source) => source.close(),
    );
  } catch (e) {
    if (context.mounted) await showSourceError(context, 'Cannot open $name', e);
    return null;
  }
  if (source == null) return null;
  try {
    if (!context.mounted) return null;
    final inner = await showSourceBrowser(
      context,
      source: source,
      title: 'Choose a folder in $name',
      subtitle: archivePath,
      rootLabel: name,
    );
    return inner == null ? null : ArchiveSource(archivePath, innerPath: inner);
  } finally {
    await source.close();
  }
}

/// Connects to an SFTP server (verifying its host key) and lets the user
/// browse to a folder, or to a file when [folder] is false. The returned
/// spec carries the secret in memory. Returns null when cancelled.
Future<SftpSource?> pickRemoteSource(BuildContext context,
    {required bool folder}) async {
  _reuseSourcesOnThisIsolate();
  final connection = await showRemoteConnectDialog(context);
  if (connection == null) return null;
  final source = connection.source;
  final account = source.spec;
  try {
    RemoteCredentialCache.remember(account, connection.secret);
    final saved = await SavedConnectionsStore.shared();
    final previous = saved.find(
        username: account.username, host: account.host, port: account.port);
    final start = await _startFolder(source, previous?.lastPath);
    if (!context.mounted) return null;

    final relative = await showSourceBrowser(
      context,
      source: source,
      title: folder ? 'Choose a folder' : 'Choose a file',
      subtitle: '${account.authority} · SFTP',
      rootLabel: '/',
      initialPath: start,
      pickFolder: folder,
      displayPath: (relative) => '/$relative',
    );
    if (relative == null) return null;
    final path = '/$relative';

    if (previous != null) {
      await saved.remember(previous.copyWith(
        lastPath: folder ? path : p.posix.dirname(path),
        lastUsed: DateTime.now(),
      ));
    }
    return SftpSource(
      host: account.host,
      port: account.port,
      username: account.username,
      path: path,
      hostKeySha256: source.hostKeySha256,
      secret: connection.secret,
    );
  } catch (e) {
    if (context.mounted) {
      await showSourceError(context, 'Cannot browse ${account.host}', e);
    }
    return null;
  } finally {
    await source.close();
  }
}

/// Where the remote browser starts, relative to `/`: the folder used last
/// time when it still exists, otherwise the user's home folder.
Future<String> _startFolder(SftpFileSource root, String? lastPath) async {
  String strip(String path) => path.replaceFirst(RegExp(r'^/+'), '');
  if (lastPath != null && lastPath.startsWith('/')) {
    try {
      final entry = await root.stat(strip(lastPath));
      if (entry != null && entry.isDirectory) return strip(lastPath);
    } on SftpSourceException {
      // Fall back to home.
    }
  }
  try {
    return strip(await root.homeDirectory());
  } on SftpSourceException {
    return '';
  }
}

/// Makes every side of [comparison] ready to open: SFTP sides restored
/// from recents or the last session carry no secret, so this asks for the
/// password or key (reusing ones entered earlier in this run) and checks
/// the host key. Returns null when the user cancels.
Future<Comparison?> ensureComparisonReady(
    BuildContext context, Comparison comparison) async {
  _reuseSourcesOnThisIsolate();
  final ready = <String, SftpSource>{};
  for (final side in _sides(comparison)) {
    if (side is! SftpSource || side.secret != null) continue;
    final key = _accountOf(side);
    if (ready.containsKey(key)) continue;
    if (!context.mounted) return null;
    final signedIn = await _signIn(context, side);
    if (signedIn == null) return null;
    ready[key] = signedIn;
  }
  if (ready.isEmpty) return comparison;

  SourceSpec fill(SourceSpec spec) {
    if (spec is! SftpSource || spec.secret != null) return spec;
    final account = ready[_accountOf(spec)]!;
    return spec.withSecret(account.secret, hostKey: account.hostKeySha256);
  }

  return _mapSides(comparison, fill);
}

String _accountOf(SftpSource s) =>
    accountKey(username: s.username, host: s.host, port: s.port);

/// Signs in to [spec]'s account: silently with a secret entered earlier in
/// this run, otherwise (or when that no longer works) by asking. Returns
/// the spec with the secret and the verified host key, or null when the
/// user cancelled.
Future<SftpSource?> _signIn(BuildContext context, SftpSource spec) async {
  String? problem;
  final cached = RemoteCredentialCache.lookup(spec);
  if (cached != null) {
    try {
      final source = await connectWithVerifiedHostKey(
        context,
        spec.withSecret(cached),
        attempt: (connect) => runWithProgress(
          context,
          message: 'Connecting to ${spec.authority}…',
          task: connect,
          discard: (source) => source.close(),
        ),
      );
      if (source == null) return null;
      final verified = spec.withSecret(cached, hostKey: source.hostKeySha256);
      await source.close();
      return verified;
    } on SftpAuthFailed catch (e) {
      RemoteCredentialCache.forget(spec);
      problem = e.message;
    } on SftpPrivateKeyError catch (e) {
      RemoteCredentialCache.forget(spec);
      problem = e.message;
    } on SftpSourceException catch (e) {
      problem = e.message;
    }
  }

  if (!context.mounted) return null;
  final connection =
      await showRemoteConnectDialog(context, account: spec, initialError: problem);
  if (connection == null) return null;
  final source = connection.source;
  RemoteCredentialCache.remember(spec, connection.secret);
  final verified =
      spec.withSecret(connection.secret, hostKey: source.hostKeySha256);
  await source.close();
  return verified;
}

/// The sides of [comparison] that are files or folders.
List<SourceSpec> _sides(Comparison comparison) {
  if (comparison is FolderComparison) {
    return [comparison.left, comparison.right];
  }
  if (comparison is FileComparison) return [comparison.left, comparison.right];
  if (comparison is ThreeWayComparison) {
    return [
      comparison.left,
      comparison.base,
      comparison.right,
      ?comparison.output,
    ];
  }
  return const [];
}

/// [comparison] with every side passed through [map]. Kinds of comparison
/// without file sides come back unchanged.
Comparison _mapSides(Comparison comparison, SourceSpec Function(SourceSpec) map) {
  if (comparison is FolderComparison) {
    return FolderComparison(map(comparison.left), map(comparison.right));
  }
  if (comparison is FileComparison) {
    return FileComparison(map(comparison.left), map(comparison.right),
        titleOverride: comparison.titleOverride);
  }
  if (comparison is ThreeWayComparison) {
    final output = comparison.output;
    return ThreeWayComparison(
      left: map(comparison.left),
      base: map(comparison.base),
      right: map(comparison.right),
      output: output == null ? null : map(output),
    );
  }
  return comparison;
}
