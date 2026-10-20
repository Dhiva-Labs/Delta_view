/// Pickers for the non-local sides of a comparison, used by the home
/// screen's Left / Right cards.
library;

import 'package:flutter/material.dart';

import '../../compare/sources/source_spec.dart';

/// Whether archive and remote sources can be picked yet. The home screen
/// hides the "Archive…" and "Remote…" choices while this is false.
const archivePickerAvailable = false;
const remotePickerAvailable = false;

/// Lets the user choose an archive (and optionally a folder inside it).
/// Returns null when cancelled. Placeholder until archive support lands.
Future<ArchiveSource?> pickArchiveSource(BuildContext context) async => null;

/// Connects to an SFTP server (verifying its host key) and lets the user
/// browse to a folder, or to a file when [folder] is false. The returned
/// spec carries the secret in memory. Returns null when cancelled.
/// Placeholder until remote support lands.
Future<SftpSource?> pickRemoteSource(BuildContext context,
        {required bool folder}) async =>
    null;
