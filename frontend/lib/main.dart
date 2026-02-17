import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_settings_controller.dart';
import 'services/library_controller.dart';
import 'widgets/app_settings_scope.dart';
import 'widgets/library_scope.dart';

void main() {
  runApp(const CoreReader());
}

class CoreReader extends StatefulWidget {
  const CoreReader({super.key});

  @override
  State<CoreReader> createState() => _CoreReaderState();
}

class _CoreReaderState extends State<CoreReader> {
  late final AppSettingsController _settings;
  late final LibraryController _library;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsController();
    _library = LibraryController();
  }

  @override
  void dispose() {
    _settings.dispose();
    _library.dispose();
    super.dispose();
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.wait([
        _settings.load(),
        _library.load(),
      ]),
      builder: (context, snapshot) {
        return AppSettingsScope(
          controller: _settings,
          child: LibraryScope(
            controller: _library,
            child: AnimatedBuilder(
              animation: _settings,
              builder: (context, _) {
                return MaterialApp(
                  title: 'CoreReader',
                  theme: ThemeData(
                    colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
                    useMaterial3: true,
                    brightness: Brightness.light,
                  ),
                  darkTheme: ThemeData(
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: Colors.deepPurple,
                      brightness: Brightness.dark,
                    ),
                    useMaterial3: true,
                    brightness: Brightness.dark,
                  ),
                  themeMode: _settings.themeMode,
                  home: const CoreReaderApp(),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
