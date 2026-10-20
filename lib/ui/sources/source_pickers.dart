/// Pickers for the non-local sides of a comparison, used by the home
/// screen's Left / Right cards.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../compare/comparison.dart';
import '../../compare/sources/archive_source.dart';
import '../../compare/sources/file_source.dart';
import 'source_browser_dialog.dart';
import 'source_ui.dart';

/// Whether archive and remote sources can be picked yet. The home screen
/// hides the "Archive…" and "Remote…" choices while this is false.
const archivePickerAvailable = true;
const remotePickerAvailable = false;

/// Every view opens its own source on the main isolate, so keep archives
/// indexed between them for a while. (Background isolates keep the
/// default and let go as soon as they finish.)
void _reuseSourcesOnThisIsolate() {
  ArchiveFileSource.keepRecentArchivesOpen = true;
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
/// Placeholder until remote support lands.
Future<SftpSource?> pickRemoteSource(BuildContext context,
        {required bool folder}) async =>
    null;

/// Makes every side of [comparison] ready to open: SFTP sides restored
/// from recents or the last session carry no secret, so this asks for the
/// password or key (reusing ones entered earlier in this run) and checks
/// the host key. Returns null when the user cancels.
/// Placeholder: returns [comparison] unchanged until remote support lands.
Future<Comparison?> ensureComparisonReady(
    BuildContext context, Comparison comparison) async {
  _reuseSourcesOnThisIsolate();
  return comparison;
}
