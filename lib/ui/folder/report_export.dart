/// Saving a folder comparison report where the user chooses, and the
/// dialog listing what the scan could not read.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../compare/comparison.dart';
import '../../compare/folder_compare.dart';
import '../../compare/folder_report.dart';
import '../../theme.dart';
import 'tree_model.dart';

/// Asks where to save and writes the report of [result] as HTML or CSV,
/// listing what [tree] shows (its filter and search). Returns the path
/// written, or null when the user cancelled. Throws
/// [FileSystemException] when the file cannot be written.
Future<String?> saveFolderReport({
  required ScanResult result,
  required SourceSpec left,
  required SourceSpec right,
  required FolderTreeModel tree,
  required bool html,
}) async {
  final extension = html ? 'html' : 'csv';
  String safe(String s) => s.replaceAll(RegExp(r'[^\w.\-]+'), '_');
  final location = await getSaveLocation(
    suggestedName: '${safe(left.label)}-vs-${safe(right.label)}.$extension',
    acceptedTypeGroups: [
      html
          ? const XTypeGroup(label: 'HTML page', extensions: ['html', 'htm'])
          : const XTypeGroup(label: 'CSV', extensions: ['csv']),
    ],
  );
  if (location == null) return null;
  // Some save dialogs return the name exactly as typed.
  var path = location.path;
  final lower = path.toLowerCase();
  if (!lower.endsWith('.$extension') && !(html && lower.endsWith('.htm'))) {
    path = '$path.$extension';
  }
  final query = tree.query;
  final report = FolderReport(
    result: result,
    leftDescription: left.description,
    rightDescription: right.description,
    include: tree.isShown,
    scopeLabel: query.isEmpty
        ? tree.filter.label
        : '${tree.filter.label}, names containing “$query”',
  );
  await File(path).writeAsString(html ? report.toHtml() : report.toCsv());
  return path;
}

/// Lists the folders and files the scan could not read.
Future<void> showScanIssues(BuildContext context, ScanResult result) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final n = result.issues.length;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded,
              color: DiffPalette.of(context).modified),
          title: Text('$n ${n == 1 ? 'entry' : 'entries'} could not be read'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final issue in result.issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: issue.path,
                          style: monoStyle.copyWith(fontSize: 12)),
                      TextSpan(
                          text: '  ${issue.message}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant)),
                    ])),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
