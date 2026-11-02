import 'dart:math';

import 'package:flutter/material.dart';

/// AgriPulse "field instrument" palette, shared with the web dashboard.
abstract final class AP {
  static const ink = Color(0xFF0F1F17);
  static const ink2 = Color(0xFF33433A);
  static const muted = Color(0xFF4E5E54);
  static const bg = Color(0xFFF3F5EF);
  static const card = Colors.white;
  static const line = Color(0xFFE2E6DC);
  static const line2 = Color(0xFFD4DACE);
  static const forest = Color(0xFF1F5C3B);
  static const lime = Color(0xFFC8F169);
  static const limeSoft = Color(0xFFE3F2B8);
  static const night = Color(0xFF0B1711); // navigate screen
  static const night2 = Color(0xFF14271D);
  static const night3 = Color(0xFF1C3527);
  static const nightLine = Color(0xFF22402F);
  static const onDark = Color(0xFFC3D0C7);
  static const onDarkMuted = Color(0xFF9DB0A3);
  static const alertBg = Color(0xFFFBE7E2);
  static const alert = Color(0xFFA8301A);
  static const okBg = Color(0xFFDDF0E3);
  static const zone = Color(0xFFFF5A3C);
  static const note = Color(0xFF3EC5F0);
  static const noteRing = Color(0xFF0B2530);
  static const me = Color(0xFF2A78D6);
  static const pending = Color(0xFFE7A322);
  static const mapGround = Color(0xFF3A4734);

  static const sans = 'Manrope';
  static const mono = 'JetBrainsMono';

  static TextStyle monoStyle(double size, {Color? color, FontWeight weight = FontWeight.w600}) =>
      TextStyle(fontFamily: mono, fontSize: size, fontWeight: weight, color: color, letterSpacing: -0.2);
}

ThemeData agriTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AP.forest,
    primary: AP.ink,
    onPrimary: Colors.white,
    secondary: AP.lime,
    onSecondary: AP.ink,
    surface: AP.bg,
    onSurface: AP.ink,
    error: AP.alert,
  );
  final base = ThemeData(colorScheme: scheme, fontFamily: AP.sans, useMaterial3: true);
  final t = base.textTheme;
  return base.copyWith(
    scaffoldBackgroundColor: AP.bg,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: t.copyWith(
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6, color: AP.ink),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4, color: AP.ink),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: AP.ink),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: AP.ink),
      bodySmall: t.bodySmall?.copyWith(color: AP.muted),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: AP.bg, foregroundColor: AP.ink, elevation: 0, scrolledUnderElevation: 0),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AP.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontFamily: AP.sans, fontSize: 17, fontWeight: FontWeight.w800),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AP.line2, width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AP.line2, width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AP.forest, width: 1.5)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: AP.ink),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: AP.limeSoft,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: AP.sans,
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w700,
            color: s.contains(WidgetState.selected) ? AP.ink : AP.muted,
          )),
    ),
  );
}

/// Red–yellow–green NDVI ramp, identical to the web dashboard and the TiTiler `rdylgn` tiles.
Color ndviColor(double v) {
  const stops = <(double, Color)>[
    (-0.2, Color(0xFFA50026)), (0.1, Color(0xFFF46D43)), (0.3, Color(0xFFFEE08B)),
    (0.5, Color(0xFFA6D96A)), (0.7, Color(0xFF1A9850)), (0.9, Color(0xFF006837)),
  ];
  for (var i = 1; i < stops.length; i++) {
    if (v <= stops[i].$1 || i == stops.length - 1) {
      final t = ((v - stops[i - 1].$1) / (stops[i].$1 - stops[i - 1].$1)).clamp(0.0, 1.0);
      return Color.lerp(stops[i - 1].$2, stops[i].$2, t)!;
    }
  }
  return stops.last.$2;
}

enum TargetState { open, next, scouted }

/// Numbered stress-target marker. 1 = most stressed.
class TargetBadge extends StatelessWidget {
  const TargetBadge({super.key, required this.rank, this.state = TargetState.open, this.size = 34, this.onMap = false});

  final int rank;
  final TargetState state;
  final double size;
  final bool onMap; // white ring + shadow over imagery

  @override
  Widget build(BuildContext context) {
    final (bg, fg, ring) = switch (state) {
      TargetState.scouted => (onMap ? Colors.white : AP.okBg, AP.forest, onMap ? AP.forest : null),
      TargetState.next => (AP.lime, AP.ink, onMap ? AP.ink : null),
      TargetState.open => (AP.ink, Colors.white, onMap ? Colors.white : null),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring, width: 2.5),
        boxShadow: onMap ? const [BoxShadow(blurRadius: 8, color: Color(0x59000000), offset: Offset(0, 3))] : null,
      ),
      child: Text('$rank', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: size * 0.42)),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.bg = AP.bg, this.fg = AP.muted, this.icon});

  factory Pill.alert(String text) => Pill(text, bg: AP.alertBg, fg: AP.alert, icon: Icons.south);
  factory Pill.ok(String text, {Key? key, IconData? icon = Icons.check}) =>
      Pill(text, key: key, bg: AP.okBg, fg: AP.forest, icon: icon);

  final String text;
  final Color bg, fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
          Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label});

  final String value, label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AP.bg, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: AP.monoStyle(17), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AP.muted)),
        ]),
      );
}

/// Decorative NDVI mosaic for the sign-in screen (not data).
class NdviMosaic extends StatelessWidget {
  const NdviMosaic({super.key, this.size = 250});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _MosaicPainter()));
}

class _MosaicPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const n = 20;
    final cell = size.width / n;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final v = r >= 13 && r <= 14 ? 0.58 : r <= 12 && c >= 12 ? 0.8 : r <= 12 && c == 11 ? 0.62
            : r >= 9 && r <= 12 ? 0.2 : r <= 8 ? 0.5 : c <= 2 ? 0.27 : c <= 6 ? 0.66 : 0.26;
        final h = sin(c * 12.9898 + r * 78.233) * 43758.5453;
        canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell + 0.5, cell + 0.5),
            Paint()..color = ndviColor(v + (h - h.floorToDouble() - 0.5) * 0.08));
      }
    }
  }

  @override
  bool shouldRepaint(_MosaicPainter oldDelegate) => false;
}
