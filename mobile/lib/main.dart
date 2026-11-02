import 'package:flutter/material.dart';

import 'screens/fields_screen.dart';
import 'screens/login_screen.dart';
import 'services.dart';

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

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F7D4A), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      // Outdoor use: larger tap targets.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 52), textStyle: const TextStyle(fontSize: 16)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: MaterialApp(
        title: 'AgriPulse Scout',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: Builder(
          builder: (context) =>
              ServicesScope.of(context).signedIn ? const FieldsScreen() : const LoginScreen(),
        ),
      ),
    );
  }
}
