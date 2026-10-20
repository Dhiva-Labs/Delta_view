import 'dart:convert';
import 'dart:io';

import 'package:delta_view/compare/sources/file_source.dart';
import 'package:delta_view/compare/sources/sftp_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests that need no server run everywhere. The rest run against a real
/// SSH server when these are set (key authentication only):
///
///   DELTAVIEW_SFTP_HOST, DELTAVIEW_SFTP_PORT, DELTAVIEW_SFTP_USER,
///   DELTAVIEW_SFTP_KEY (private key file), DELTAVIEW_SFTP_FINGERPRINT
///   (the server's SHA256 host key fingerprint, as ssh-keygen -lf prints
///   it), DELTAVIEW_SFTP_DIR (an absolute folder the tests may fill and
///   remove), and optionally DELTAVIEW_SFTP_ENCRYPTED_KEY with
///   DELTAVIEW_SFTP_PASSPHRASE.
void main() {
  test('needs credentials before connecting', () async {
    await expectLater(
      FileSource.open(const SftpSource(
          host: 'example.invalid', username: 'me', path: '/srv')),
      throwsA(isA<SftpCredentialsRequired>()),
    );
  });

  test('explains an unreachable host', () async {
    await expectLater(
      FileSource.open(const SftpSource(
        host: '127.0.0.1',
        port: 1,
        username: 'me',
        path: '/',
        hostKeySha256: 'AAAA',
        secret: SftpSecret(password: 'x'),
      )),
      throwsA(isA<SftpHostUnreachable>()
          .having((e) => e.message, 'message', contains('refused'))),
    );
  });

  test('turns OpenSSH fingerprints into the stored form', () {
    expect(normalizeSshFingerprint('SHA256:abc+/def'), 'abc+/def');
    expect(normalizeSshFingerprint(' abc= '), 'abc');
  });

  final env = Platform.environment;
  final host = env['DELTAVIEW_SFTP_HOST'];
  group('against a live server', () {
    late SftpSource base;
    late String dir;

    setUpAll(() {
      dir = env['DELTAVIEW_SFTP_DIR']!;
      base = SftpSource(
        host: host!,
        port: int.parse(env['DELTAVIEW_SFTP_PORT'] ?? '22'),
        username: env['DELTAVIEW_SFTP_USER']!,
        path: dir,
        hostKeySha256:
            normalizeSshFingerprint(env['DELTAVIEW_SFTP_FINGERPRINT']!),
        secret: SftpSecret(
            privateKeyPem: File(env['DELTAVIEW_SFTP_KEY']!).readAsStringSync()),
      );
    });

    test('refuses a host key nobody accepted, before signing in', () async {
      final unverified = SftpSource(
          host: base.host,
          port: base.port,
          username: base.username,
          path: dir,
          secret: base.secret);
      await expectLater(
        FileSource.open(unverified),
        throwsA(isA<SftpHostKeyNotTrusted>().having(
            (e) => e.fingerprint, 'fingerprint', base.hostKeySha256)),
      );
    });

    test('refuses a host key that does not match', () async {
      await expectLater(
        FileSource.open(base.withSecret(base.secret,
            hostKey: 'AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFake')),
        throwsA(isA<SftpHostKeyMismatch>()
            .having((e) => e.fingerprint, 'fingerprint', base.hostKeySha256)),
      );
    });

    test('reports a key the server does not accept', () async {
      final tmp = await Directory.systemTemp.createTemp('deltaview-key-');
      addTearDown(() => tmp.delete(recursive: true));
      final keyFile = '${tmp.path}/other';
      final result = await Process.run(
          'ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', keyFile]);
      expect(result.exitCode, 0);
      await expectLater(
        FileSource.open(base.withSecret(
            SftpSecret(privateKeyPem: File(keyFile).readAsStringSync()))),
        throwsA(isA<SftpAuthFailed>()),
      );
    });

    test('reads, writes, lists and deletes', () async {
      final source = await FileSource.open(base.child('deltaview-test'));
      addTearDown(() async {
        await source.delete('');
        await source.close();
      });

      await source.write('a/b/c.txt', utf8.encode('hello'));
      expect(utf8.decode(await source.read('a/b/c.txt')), 'hello');
      await source.write('a/b/c.txt', utf8.encode('replaced'));
      expect(utf8.decode(await source.read('a/b/c.txt')), 'replaced');

      final entry = (await source.stat('a/b/c.txt'))!;
      expect(entry.isDirectory, isFalse);
      expect(entry.size, 8);
      expect(entry.modified, isNotNull);

      await source.createDirectory('x/y/z');
      expect((await source.stat('x/y/z'))!.isDirectory, isTrue);
      expect({for (final e in await source.list('')) e.name}, {'a', 'x'});
      // No temporary files left behind by the safe write.
      expect([for (final e in await source.list('a/b')) e.name], ['c.txt']);

      await source.delete('a');
      expect(await source.stat('a'), isNull);
      expect(await source.stat('a/b/c.txt'), isNull);
      expect(source.writable, isTrue);
    });

    test('shares one connection between sources', () async {
      SftpFileSource.shareConnections = true;
      addTearDown(() async {
        SftpFileSource.shareConnections = false;
        await closeSharedSftpConnections();
      });
      final first = Stopwatch()..start();
      final a = await FileSource.open(base);
      first.stop();
      await a.close();
      final second = Stopwatch()..start();
      final b = await FileSource.open(base);
      second.stop();
      await b.close();
      expect(second.elapsedMicroseconds, lessThan(first.elapsedMicroseconds));
    });

    final encrypted = env['DELTAVIEW_SFTP_ENCRYPTED_KEY'];
    test('uses passphrase-protected keys', () async {
      final pem = File(encrypted!).readAsStringSync();
      await expectLater(
        FileSource.open(base.withSecret(SftpSecret(privateKeyPem: pem))),
        throwsA(isA<SftpPrivateKeyError>()
            .having((e) => e.needsPassphrase, 'needsPassphrase', isTrue)),
      );
      await expectLater(
        FileSource.open(base.withSecret(
            SftpSecret(privateKeyPem: pem, passphrase: 'wrong'))),
        throwsA(isA<SftpPrivateKeyError>()),
      );
      final source = await FileSource.open(base.withSecret(SftpSecret(
          privateKeyPem: pem, passphrase: env['DELTAVIEW_SFTP_PASSPHRASE'])));
      expect(await source.stat(''), isNotNull);
      await source.close();
    }, skip: encrypted == null ? 'No encrypted key given' : null);
  }, skip: host == null ? 'Set DELTAVIEW_SFTP_HOST to run' : null);
}
