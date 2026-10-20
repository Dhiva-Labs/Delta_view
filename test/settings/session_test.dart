import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/settings/app_settings.dart';
import 'package:delta_view/ui/shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const folders = FolderComparison(LocalSource('/a'), LocalSource('/b'));
  const files = FileComparison(LocalSource('/a/x'), LocalSource('/b/x'));
  const merge = ThreeWayComparison(
    left: LocalSource('/m/l'),
    base: LocalSource('/m/b'),
    right: LocalSource('/m/r'),
    output: LocalSource('/m/out'),
  );
  const remote = FolderComparison(
    LocalSource('/srv'),
    SftpSource(
        host: 'example.org', username: 'me', path: '/srv', port: 2222),
  );

  group('sessionJsonOf', () {
    test('keeps comparisons and skips picker tabs', () {
      final json = sessionJsonOf([folders, null, files]);
      expect(json, [folders.toJson(), files.toJson()]);
    });

    test('leaves out text too large to remember', () {
      final big = TextComparison(leftText: 'x' * (300 * 1024));
      expect(sessionJsonOf([big, folders]), [folders.toJson()]);
      expect(sessionJsonOf([const TextComparison(leftText: 'a')]),
          hasLength(1));
    });
  });

  group('session round trip through AppSettings', () {
    test('survives toJson / applyJson and restores every kind', () {
      final saved = AppSettings()
        ..sessionTabs = sessionJsonOf([folders, files, merge, remote])
        ..sessionActiveTab = 2;

      final loaded = AppSettings()..applyJson(saved.toJson());
      final session = restoreSession(loaded);

      expect(session.active, 2);
      expect(session.comparisons, hasLength(4));
      expect(session.comparisons[0], isA<FolderComparison>());
      expect(session.comparisons[1], isA<FileComparison>());
      final restoredMerge = session.comparisons[2] as ThreeWayComparison;
      expect(restoredMerge.output, const LocalSource('/m/out'));
      final restoredRemote = session.comparisons[3] as FolderComparison;
      final sftp = restoredRemote.right as SftpSource;
      expect(sftp.port, 2222);
      expect(sftp.secret, isNull, reason: 'secrets are never saved');
      // The JSON is byte-for-byte what was saved.
      expect([for (final c in session.comparisons) c.toJson()],
          saved.sessionTabs);
    });

    test('clamps the active index and skips unknown entries', () {
      final settings = AppSettings()
        ..sessionTabs = [
          folders.toJson(),
          {'type': 'hologram', 'left': 1},
          files.toJson(),
        ]
        ..sessionActiveTab = 9;
      final session = restoreSession(settings);
      expect(session.comparisons, hasLength(2));
      expect(session.active, 1);
    });

    test('an empty session restores nothing', () {
      final session = restoreSession(AppSettings()..sessionActiveTab = 3);
      expect(session.comparisons, isEmpty);
      expect(session.active, 0);
    });
  });

  test('window bounds round trip', () {
    final saved = AppSettings()
      ..windowBounds = const WindowBounds(10, 20, 1100, 700, maximized: true);
    final loaded = AppSettings()..applyJson(saved.toJson());
    final b = loaded.windowBounds!;
    expect((b.x, b.y, b.width, b.height, b.maximized), (10, 20, 1100, 700, true));
  });
}
