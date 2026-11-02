import 'package:flutter/material.dart';

import '../services.dart';
import 'fields_screen.dart';
import 'notes_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final sync = ServicesScope.of(context).sync;
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        const FieldsScreen(),
        NotesScreen(key: ValueKey('notes-$_tab'), outbox: false),
        NotesScreen(key: ValueKey('outbox-$_tab'), outbox: true),
      ]),
      bottomNavigationBar: ListenableBuilder(
        listenable: sync ?? ValueNotifier(0),
        builder: (context, _) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Fields'),
            const NavigationDestination(icon: Icon(Icons.edit_note_outlined), selectedIcon: Icon(Icons.edit_note), label: 'My notes'),
            NavigationDestination(
              icon: Badge(isLabelVisible: (sync?.pending ?? 0) > 0, label: Text('${sync?.pending}'), child: const Icon(Icons.inbox_outlined)),
              selectedIcon: const Icon(Icons.inbox),
              label: 'Outbox',
            ),
          ],
        ),
      ),
    );
  }
}
