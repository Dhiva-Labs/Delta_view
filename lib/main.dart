import 'package:flutter/material.dart';

import 'settings/app_settings.dart';
import 'theme.dart';
import 'ui/shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await appSettings.load();
  runApp(DeltaViewApp(launchArgs: args));
}

class DeltaViewApp extends StatelessWidget {
  const DeltaViewApp({super.key, this.launchArgs = const []});

  /// Command-line arguments the app was started with.
  final List<String> launchArgs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return MaterialApp(
          title: 'DeltaView',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light, seed: appSettings.accentColor),
          darkTheme:
              buildTheme(Brightness.dark, seed: appSettings.accentColor),
          themeMode: appSettings.themeMode,
          home: const TabbedShell(),
        );
      },
    );
  }
}
