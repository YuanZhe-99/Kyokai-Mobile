// The navigation shell: Devices, Sessions and Settings. A phone gets
// MyApps-UI's floating pill bar; 600 dp and wider get the rail.

import 'package:flutter/material.dart';
import 'package:myapps_ui/myapps_ui.dart';

import '../../data/app_state.dart';
import '../home/home_page.dart';
import '../home/sessions_page.dart';
import '../settings/settings_page.dart';
import 'app.dart';
import 'start_gate.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final state = AppScope.of(context);
    return StartGate(
      child: ListenableBuilder(
        listenable: state.prefs,
        builder: (context, _) => MyAppsNavigationShell(
          style: state.prefs.style,
          placement: NavPlacement.sideOnWide,
          selectedIndex: _index,
          onSelected: (i) => setState(() => _index = i),
          destinations: [
            MyAppsDestination(icon: const Icon(Icons.devices_outlined), selectedIcon: const Icon(Icons.devices), label: l.navDevices),
            MyAppsDestination(icon: const Icon(Icons.cast_outlined), selectedIcon: const Icon(Icons.cast_connected), label: l.navSessions),
            MyAppsDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: l.navSettings),
          ],
          child: IndexedStack(
            index: _index,
            children: const [HomePage(), SessionsPage(), SettingsPage()],
          ),
        ),
      ),
    );
  }
}
