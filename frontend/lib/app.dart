import 'dart:ui';

import 'package:flutter/material.dart';

import 'screens/add_novel_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/theme_toggle_button.dart';

class CoreReaderApp extends StatefulWidget {
  const CoreReaderApp({super.key});

  @override
  State<CoreReaderApp> createState() => _CoreReaderAppState();
}

class _CoreReaderAppState extends State<CoreReaderApp> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CoreReader'),
        actions: const [
          ThemeToggleButton(),
          SizedBox(width: 6),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: IndexedStack(
          key: ValueKey(_index),
          index: _index,
          children: const [
            LibraryScreen(),
            AddNovelScreen(),
            SettingsScreen(),
          ],
        ),
      ),
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
                NavigationDestination(icon: Icon(Icons.local_library), label: 'Library'),
                NavigationDestination(icon: Icon(Icons.add_circle_outline), label: 'Add novel'),
                NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
