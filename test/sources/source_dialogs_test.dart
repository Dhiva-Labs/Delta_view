import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/compare/sources/file_source.dart';
import 'package:delta_view/compare/sources/sftp_source.dart';
import 'package:delta_view/remote/known_hosts.dart';
import 'package:delta_view/remote/saved_connections.dart';
import 'package:delta_view/theme.dart';
import 'package:delta_view/ui/sources/host_key_dialogs.dart';
import 'package:delta_view/ui/sources/remote_connect_dialog.dart';
import 'package:delta_view/ui/sources/source_browser_dialog.dart';
import 'package:delta_view/ui/sources/source_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pumps an app whose single button runs [open] and records its result.
Future<List<Object?>> _host(WidgetTester tester,
    Future<Object?> Function(BuildContext context) open,
    {Brightness brightness = Brightness.light}) async {
  final results = <Object?>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () async => results.add(await open(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('the browser lists folders first and returns the chosen one',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final source = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('deltaview-browse-');
      addTearDown(() => dir.delete(recursive: true));
      final archive = Archive()
        ..add(ArchiveFile.bytes('zeta.txt', utf8.encode('z')))
        ..add(ArchiveFile.bytes('alpha/inner/a.txt', utf8.encode('a')))
        ..add(ArchiveFile.bytes('beta/b.txt', utf8.encode('b')));
      final path = p.join(dir.path, 'pkg.zip');
      await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
      return FileSource.open(ArchiveSource(path));
    }))!;
    addTearDown(source.close);

    final results = await _host(
      tester,
      (context) => showSourceBrowser(context,
          source: source, title: 'Choose a folder in pkg.zip', rootLabel: 'pkg.zip'),
    );

    final names = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ListView), matching: find.byType(Text)))
        .map((t) => t.data)
        .where((d) => d == 'alpha' || d == 'beta' || d == 'zeta.txt')
        .toList();
    expect(names, ['alpha', 'beta', 'zeta.txt']);

    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('inner'), findsOneWidget);
    expect(find.text('pkg.zip'), findsOneWidget); // breadcrumb

    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();
    expect(results, ['alpha']);
  });

  testWidgets('the trust dialog shows the key and what ssh knows about it',
      (tester) async {
    const key = SftpHostKeyNotTrusted(
        host: 'build.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'zpT6+C4tm1uzpqoICNae2nqKl6Hpxd+HBE4dVy7I14w');
    final results = await _host(
      tester,
      (context) => showTrustHostDialog(context, key,
          system: SystemKnownHostsMatch.matches),
      brightness: Brightness.dark,
    );
    expect(find.text('Trust this host?'), findsOneWidget);
    expect(find.text('SHA256:${key.fingerprint}'), findsOneWidget);
    expect(find.textContaining('already trusts this key'), findsOneWidget);

    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();
    expect(results, [true]);
  });

  testWidgets('a revoked key cannot be trusted', (tester) async {
    const key = SftpHostKeyNotTrusted(
        host: 'h', port: 22, keyType: 'ssh-rsa', fingerprint: 'abc');
    await _host(
      tester,
      (context) => showTrustHostDialog(context, key,
          system: SystemKnownHostsMatch.revoked),
    );
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Trust and connect'));
    expect(button.onPressed, isNull);
  });

  testWidgets('a changed key is refused until the old one is removed',
      (tester) async {
    final store = KnownHostsStore();
    await store.trust(
        host: 'h', port: 22, keyType: 'ssh-ed25519', fingerprint: 'old');
    const mismatch = SftpHostKeyMismatch(
        host: 'h',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'new',
        expected: 'old');
    final results = await _host(
        tester, (context) => showHostKeyChangedDialog(context, mismatch, store));
    expect(find.text('The identity of h has changed'), findsOneWidget);
    expect(find.text('SHA256:old'), findsOneWidget);
    expect(find.text('SHA256:new'), findsOneWidget);

    await tester.tap(find.text('Don’t connect'));
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(store.lookup('h', 22)!.fingerprint, 'old');
  });

  testWidgets('the connect dialog lists saved connections and fills the form',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final saved = SavedConnectionsStore();
    await saved.remember(const SavedConnection(
        host: 'files.example.com', port: 2222, username: 'deploy'));
    await _host(
      tester,
      (context) => showDialog<RemoteConnection>(
        context: context,
        builder: (context) => RemoteConnectDialog(saved: saved),
      ),
    );
    expect(find.text('Connect to a server'), findsOneWidget);
    expect(find.text('files.example.com:2222'), findsOneWidget);
    expect(find.text('deploy · password'), findsOneWidget);

    await tester.tap(find.text('files.example.com:2222'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'files.example.com'), findsOneWidget);
    expect(find.widgetWithText(TextField, '2222'), findsOneWidget);

    // Asking for a key file without choosing one explains what is missing.
    await tester.tap(find.text('Private key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Choose your private key file.'), findsOneWidget);
  });

  testWidgets('comparisons without remote sides pass through', (tester) async {
    const comparison =
        FolderComparison(LocalSource('/a'), ArchiveSource('/b.zip'));
    final results =
        await _host(tester, (context) => ensureComparisonReady(context, comparison));
    expect(results.single, same(comparison));
  });
}
