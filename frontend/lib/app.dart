import 'dart:ui';

import 'package:flutter/material.dart';

import 'screens/reader_screen.dart';
import 'screens/settings_screen.dart';

class CoreReaderApp extends StatefulWidget {
  const CoreReaderApp({super.key});

  @override
  State<CoreReaderApp> createState() => _CoreReaderAppState();
}

class _CoreReaderAppState extends State<CoreReaderApp> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [ReaderScreen(), SettingsScreen()];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.menu_book), label: 'Reader'),
                NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
