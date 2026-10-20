import 'dart:convert';
import 'dart:io';

import 'package:delta_view/compare/sources/source_spec.dart';
import 'package:delta_view/remote/credential_cache.dart';
import 'package:delta_view/remote/known_hosts.dart';
import 'package:delta_view/remote/remote_address.dart';
import 'package:delta_view/remote/saved_connections.dart';
import 'package:delta_view/remote/sha256.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Public keys generated with ssh-keygen, and the fingerprints
/// `ssh-keygen -lf` printed for them.
const _ed25519 = 'AAAAC3NzaC1lZDI1NTE5AAAAIPtU/7QRwVg2/IHmb/Zdq9WH8OJmUW0qVaXwI3di2Cn1';
const _ed25519Fingerprint = 'zpT6+C4tm1uzpqoICNae2nqKl6Hpxd+HBE4dVy7I14w';
const _rsa = 'AAAAB3NzaC1yc2EAAAADAQABAAABAQCeos0allqRDRnZmNHm/wtjvT3VG6jBVFu+A1OQ623v9ROLCGFru90Ba7yidvTv0uSk1WjkraYFVvZlmbXiyYpMfhQahDBFuaSv0p29N+3Q6Z6FofnDfPFxM8fA/tsiD/ybRF2IKsjFX47PZy4TKG2iQ53Ql4ZwQKxQ/rXkBpSmGc/nEBQ6bkP+44QER+aCgzstRiw6N0+wngYnFPbjxORhHfm858awZzbqVZ+TaObfTtumEao72yUWssG1fyvUpLpijlDr0VkIYQ5nJMyLryGbi8+RtSI95JSW7AHwL5tQCUV8XULvECeId9foZfZqjLXhud5k9ExM7/kzSSlIxLxP';
const _rsaFingerprint = 'XgSAAOMT2S7YJRWcj9hHCgfQfQ4VQOL/xj/n7Vpbsa0';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('deltaview-remote-test-');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('fingerprints', () {
    test('SHA-256 matches the standard test vectors', () {
      expect(_hex(sha256([])),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(_hex(sha256(utf8.encode('abc'))),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          _hex(sha256(utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(_hex(sha256(List.filled(1000000, 0x61))),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });

    test('match what ssh-keygen prints', () {
      expect(openSshFingerprint(base64.decode(_ed25519)), _ed25519Fingerprint);
      expect(openSshFingerprint(base64.decode(_rsa)), _rsaFingerprint);
    });

    test('key types read well', () {
      expect(keyTypeLabel('ssh-ed25519'), 'ED25519');
      expect(keyTypeLabel('rsa-sha2-512'), 'RSA');
      expect(keyTypeLabel('ecdsa-sha2-nistp256'), 'ECDSA P-256');
    });
  });

  group('known hosts store', () {
    test('records, verifies and forgets keys, and survives a reload',
        () async {
      final file = File(p.join(tmp.path, 'known_hosts.json'));
      final store = KnownHostsStore(file: file);
      await store.load();
      expect(store.verdict('Example.com', 22, _ed25519Fingerprint),
          HostKeyVerdict.unknown);

      await store.trust(
          host: 'Example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: _ed25519Fingerprint);
      expect(store.verdict('example.com', 22, _ed25519Fingerprint),
          HostKeyVerdict.trusted);
      expect(store.verdict('example.com', 22, _rsaFingerprint),
          HostKeyVerdict.changed);
      expect(store.verdict('example.com', 2222, _ed25519Fingerprint),
          HostKeyVerdict.unknown);

      final reloaded = KnownHostsStore(file: file);
      await reloaded.load();
      final host = reloaded.lookup('EXAMPLE.COM', 22)!;
      expect(host.fingerprint, _ed25519Fingerprint);
      expect(host.keyType, 'ssh-ed25519');

      await reloaded.remove('example.com', 22);
      final empty = KnownHostsStore(file: file);
      await empty.load();
      expect(empty.hosts, isEmpty);
    });

    test('never replaces a recorded key without removing it first',
        () async {
      final store = KnownHostsStore();
      await store.trust(
          host: '10.0.0.5',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: _ed25519Fingerprint);
      expect(
        () => store.trust(
            host: '10.0.0.5',
            port: 22,
            keyType: 'ssh-rsa',
            fingerprint: _rsaFingerprint),
        throwsStateError,
      );
      expect(store.lookup('10.0.0.5', 22)!.fingerprint, _ed25519Fingerprint);
    });

    test('ignores a damaged file', () async {
      final file = File(p.join(tmp.path, 'known_hosts.json'))
        ..writeAsStringSync('{not json');
      final store = KnownHostsStore(file: file);
      await store.load();
      expect(store.hosts, isEmpty);
    });
  });

  group('OpenSSH known_hosts', () {
    SystemKnownHostsMatch check(String text,
            {String host = 'build.example.com',
            int port = 22,
            String type = 'ssh-ed25519',
            String fingerprint = _ed25519Fingerprint}) =>
        matchKnownHostsText(text,
            host: host, port: port, keyType: type, fingerprint: fingerprint);

    test('finds plain entries, with ports and aliases', () {
      expect(check('build.example.com ssh-ed25519 $_ed25519\n'),
          SystemKnownHostsMatch.matches);
      expect(check('ci,build.example.com,10.1.1.1 ssh-ed25519 $_ed25519 me'),
          SystemKnownHostsMatch.matches);
      expect(check('[build.example.com]:2222 ssh-ed25519 $_ed25519',
              port: 2222),
          SystemKnownHostsMatch.matches);
      expect(check('[build.example.com]:2222 ssh-ed25519 $_ed25519'),
          SystemKnownHostsMatch.none);
    });

    test('reports a different key of the same type', () {
      expect(check('build.example.com ssh-rsa $_rsa'),
          SystemKnownHostsMatch.none);
      expect(
          check('build.example.com ssh-rsa $_rsa',
              type: 'rsa-sha2-512', fingerprint: 'other'),
          SystemKnownHostsMatch.differs);
    });

    test('skips hashed entries, patterns and comments', () {
      expect(
          check('# build.example.com ssh-ed25519 $_ed25519\n'
              '|1|abc=|def= ssh-ed25519 $_ed25519\n'
              '*.example.com ssh-ed25519 $_ed25519\n'
              '@cert-authority build.example.com ssh-ed25519 $_ed25519\n'),
          SystemKnownHostsMatch.none);
    });

    test('notices revoked keys', () {
      expect(check('@revoked build.example.com ssh-ed25519 $_ed25519'),
          SystemKnownHostsMatch.revoked);
    });

    test('reads the file it is given', () async {
      final file = File(p.join(tmp.path, 'known_hosts'))
        ..writeAsStringSync('build.example.com ssh-ed25519 $_ed25519\n');
      expect(
          await checkSystemKnownHosts(
              host: 'build.example.com',
              port: 22,
              keyType: 'ssh-ed25519',
              fingerprint: _ed25519Fingerprint,
              file: file),
          SystemKnownHostsMatch.matches);
      expect(
          await checkSystemKnownHosts(
              host: 'x',
              port: 22,
              keyType: 'ssh-ed25519',
              fingerprint: _ed25519Fingerprint,
              file: File(p.join(tmp.path, 'missing'))),
          SystemKnownHostsMatch.none);
    });
  });

  group('saved connections', () {
    test('keep one entry per account, most recent first', () async {
      final file = File(p.join(tmp.path, 'remote_connections.json'));
      final store = SavedConnectionsStore(file: file);
      await store.load();
      await store.remember(const SavedConnection(
          host: 'a.example.com', username: 'deploy', lastPath: '/srv'));
      await store.remember(const SavedConnection(
          host: 'b.example.com',
          port: 2222,
          username: 'me',
          auth: RemoteAuthMethod.privateKey,
          keyPath: '/home/me/.ssh/id_ed25519'));
      await store.remember(const SavedConnection(
          host: 'A.example.com', username: 'deploy', lastPath: '/var/www'));

      final reloaded = SavedConnectionsStore(file: file);
      await reloaded.load();
      expect([for (final c in reloaded.connections) c.label],
          ['deploy@a.example.com', 'me@b.example.com:2222']);
      expect(reloaded.connections.first.lastPath, '/var/www');
      final key = reloaded.find(
          username: 'me', host: 'b.example.com', port: 2222)!;
      expect(key.auth, RemoteAuthMethod.privateKey);
      expect(key.keyPath, '/home/me/.ssh/id_ed25519');

      await reloaded.forget(key.id);
      expect(reloaded.connections, hasLength(1));
    });

    test('never write a secret', () async {
      final file = File(p.join(tmp.path, 'remote_connections.json'));
      final store = SavedConnectionsStore(file: file);
      await store.remember(const SavedConnection(
          host: 'h', username: 'u', auth: RemoteAuthMethod.privateKey,
          keyPath: '/k'));
      final text = file.readAsStringSync();
      expect(text, isNot(contains('password')));
      expect(text, isNot(contains('passphrase')));
      expect(jsonDecode(text)['connections'][0].keys,
          unorderedEquals(['host', 'port', 'username', 'auth', 'keyPath']));
    });
  });

  test('server addresses are split into user, host and port', () {
    expect(parseServerAddress('files.example.com'),
        (username: null, host: 'files.example.com', port: null));
    expect(parseServerAddress(' deploy@files.example.com:2222 '),
        (username: 'deploy', host: 'files.example.com', port: 2222));
    expect(parseServerAddress('sftp://me@host/srv/app'),
        (username: 'me', host: 'host', port: null));
    expect(parseServerAddress('[fe80::1]:2200'),
        (username: null, host: 'fe80::1', port: 2200));
    expect(parseServerAddress('fe80::1'),
        (username: null, host: 'fe80::1', port: null));
    expect(displayAddress('FE80::1', 2200), '[fe80::1]:2200');
    expect(displayAddress('Host', 22), 'host');
  });

  test('credential cache is keyed by account', () {
    addTearDown(RemoteCredentialCache.clear);
    const a = SftpSource(host: 'Host', username: 'u', path: '/one');
    const sameAccount = SftpSource(host: 'host', username: 'u', path: '/two');
    const otherPort =
        SftpSource(host: 'host', port: 2222, username: 'u', path: '/one');
    RemoteCredentialCache.remember(a, const SftpSecret(password: 'pw'));
    expect(RemoteCredentialCache.lookup(sameAccount)?.password, 'pw');
    expect(RemoteCredentialCache.lookup(otherPort), isNull);
    RemoteCredentialCache.forget(sameAccount);
    expect(RemoteCredentialCache.lookup(a), isNull);
  });
}
