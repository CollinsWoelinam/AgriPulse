import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await Services.init();
  runApp(ScoutApp(services: services));
}

class ScoutApp extends StatefulWidget {
  const ScoutApp({super.key, required this.services});

  final Services services;

  @override
  State<ScoutApp> createState() => _ScoutAppState();
}

class _ScoutAppState extends State<ScoutApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.services.sync?.syncNow(); // back from the field
  }

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: MaterialApp(
        title: 'AgriPulse Scout',
        // One light theme: outdoor readability; the navigate screen is dark on its own.
        theme: agriTheme(),
        home: Builder(
          builder: (context) =>
              ServicesScope.of(context).signedIn ? const HomeShell() : const LoginScreen(),
        ),
      ),
    );
  }
}
