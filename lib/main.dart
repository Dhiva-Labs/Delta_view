import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'cli/launch_args.dart';
import 'compare/comparison.dart';
import 'settings/app_settings.dart';
import 'theme.dart';
import 'ui/brand/app_info.dart';
import 'ui/shell.dart';
import 'ui/window/app_window.dart';

Future<void> main(List<String> args) async {
  final launch = parseLaunchArgs(args);
  if (launch.exitsEarly) {
    stdout.writeln(launch.output);
    await stdout.flush();
    exit(launch.exitCode);
  }

  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicense();
  await windowManager.ensureInitialized();
  await appSettings.load();

  // Command-line comparisons take the place of the last session.
  var comparisons = launch.comparisons;
  var active = 0;
  if (comparisons.isEmpty && appSettings.restoreSession) {
    final session = restoreSession(appSettings);
    comparisons = session.comparisons;
    active = session.active;
  }

  final shellKey = GlobalKey<TabbedShellState>();
  final window = AppWindow(
    confirmClose: () async =>
        await shellKey.currentState?.confirmCloseAll() ?? true,
    beforeClose: () async => shellKey.currentState?.saveSession(),
  );

  runApp(DeltaViewApp(
    shellKey: shellKey,
    initialComparisons: comparisons,
    initialActive: active,
    rememberInitial: launch.comparisons.isNotEmpty,
    notices: launch.problems,
    onQuitRequested: window.requestClose,
  ));
  // After runApp so the first frame is not held back by window set-up.
  await window.attach();
}

class DeltaViewApp extends StatelessWidget {
  const DeltaViewApp({
    super.key,
    this.shellKey,
    this.initialComparisons = const [],
    this.initialActive = 0,
    this.rememberInitial = false,
    this.notices = const [],
    this.onQuitRequested,
  });

  final GlobalKey<TabbedShellState>? shellKey;
  final List<Comparison> initialComparisons;
  final int initialActive;
  final bool rememberInitial;
  final List<String> notices;
  final VoidCallback? onQuitRequested;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return MaterialApp(
          title: appName,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light,
              seed: appSettings.accentColor, density: appSettings.density),
          darkTheme: buildTheme(Brightness.dark,
              seed: appSettings.accentColor, density: appSettings.density),
          themeMode: appSettings.themeMode,
          home: SettingsScope(
            child: TabbedShell(
              key: shellKey,
              initialComparisons: initialComparisons,
              initialActive: initialActive,
              rememberInitial: rememberInitial,
              startupNotices: notices,
              onQuitRequested: onQuitRequested,
            ),
          ),
        );
      },
    );
  }
}
