import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../geo.dart';
import '../location.dart';
import '../models.dart';
import '../scouting.dart';
import '../ui/theme.dart';
import 'note_screen.dart';

/// Arrow-and-distance guidance to a stress target, stepping through the field's targets.
class NavigateScreen extends StatefulWidget {
  const NavigateScreen({
    super.key,
    required this.fieldId,
    required this.fieldName,
    required this.targets,
    required this.states,
    required this.initialIndex,
  });

  final String fieldId, fieldName;
  final List<StressTarget> targets;
  final Map<String, TargetState> states;
  final int initialIndex;

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  late int _index = widget.initialIndex;
  late final Map<String, TargetState> _states = Map.of(widget.states);
  Position? _me;
  double? _compass; // raw platform heading
  String? _locationProblem;
  StreamSubscription<Position>? _positions;
  StreamSubscription<CompassEvent>? _headings;

  // iOS reports CLHeading.trueHeading; Android's rotation vector is magnetic.
  static final bool _compassIsMagnetic = Platform.isAndroid;
  static const _arrivalRadiusM = 10.0;

  StressTarget get _target => widget.targets[_index];

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _locationProblem = await ensureLocation();
    if (!mounted) return;
    if (_locationProblem == null) {
      _positions = positionStream().listen((p) => setState(() => _me = p), onError: (_) {});
    }
    _headings = FlutterCompass.events?.listen((e) => setState(() => _compass = e.heading));
    setState(() {});
  }

  @override
  void dispose() {
    _positions?.cancel();
    _headings?.cancel();
    super.dispose();
  }

  void _step(int delta) => setState(() => _index = (_index + delta) % widget.targets.length);

  Future<void> _log() async {
    final t = _target;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => NoteScreen(fieldId: widget.fieldId, fieldName: widget.fieldName, target: t),
    ));
    if (saved != true || !mounted) return;
    _states[t.zoneId] = TargetState.scouted;
    // Carry on to the next open target in priority order, or finish.
    final next = widget.targets.indexWhere((x) => _states[x.zoneId] != TargetState.scouted);
    if (next < 0) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final t = _target;
    final me = _me;
    final state = _states[t.zoneId] ?? TargetState.open;

    double? distance, bearing, heading;
    if (me != null) {
      distance = distanceMeters(me.latitude, me.longitude, t.point.latitude, t.point.longitude);
      bearing = bearingDegrees(me.latitude, me.longitude, t.point.latitude, t.point.longitude);
      if (_compass != null) {
        heading = trueHeading(_compass!, isMagnetic: _compassIsMagnetic, lat: me.latitude, lon: me.longitude);
      }
    }
    // Within the GPS error radius there is no meaningful direction left to follow.
    final arrived = distance != null && distance <= max(_arrivalRadiusM, me!.accuracy);

    return Scaffold(
      backgroundColor: AP.night,
      // No text input here; without this the keyboard of the note screen pushed on top squeezes this layout.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              _DarkButton(icon: Icons.arrow_back, label: 'Back', onTap: () => Navigator.of(context).pop()),
              Expanded(
                child: Column(children: [
                  Text('Target ${t.rank} of ${widget.targets.length}',
                      style: const TextStyle(color: AP.onDarkMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                  Text(widget.fieldName, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                ]),
              ),
              _DarkButton(icon: Icons.arrow_forward, label: 'Next target', onTap: widget.targets.length > 1 ? () => _step(1) : null),
            ]),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(color: AP.night2, borderRadius: BorderRadius.circular(18)),
            child: Row(children: [
              TargetBadge(rank: t.rank, state: state == TargetState.open ? TargetState.next : state, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: 'Stress zone · '),
                    TextSpan(text: '${(t.areaSqm / 10000).toStringAsFixed(2)} ha', style: AP.monoStyle(15, color: Colors.white)),
                  ]), style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: 'Mean NDVI '),
                    TextSpan(text: t.meanNdvi.toStringAsFixed(2), style: AP.monoStyle(13, color: Colors.white, weight: FontWeight.w400)),
                    if (state == TargetState.scouted) const TextSpan(text: ' · already scouted'),
                  ]), style: const TextStyle(color: Color(0xFFB9C8BE), fontSize: 13)),
                ]),
              ),
              Container(width: 26, height: 26, decoration: BoxDecoration(color: ndviColor(t.meanNdvi), borderRadius: BorderRadius.circular(7))),
            ]),
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (me == null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_locationProblem ?? 'Waiting for GPS…', textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                )
              else if (arrived) ...[
                Container(
                  width: 180,
                  height: 180,
                  decoration: const BoxDecoration(color: AP.night2, shape: BoxShape.circle),
                  child: const Icon(Icons.where_to_vote, size: 96, color: AP.lime),
                ),
                const SizedBox(height: 20),
                const Text("You're at the target", key: Key('arrived'),
                    style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Look around and log what you find.', style: TextStyle(color: AP.onDark, fontSize: 15)),
              ] else ...[
                SizedBox.square(
                  dimension: 280,
                  child: Stack(alignment: Alignment.center, children: [
                    // The ring is north-up without a compass, and rotates with the phone when there is one.
                    Transform.rotate(
                      angle: heading == null ? 0 : -heading * pi / 180,
                      child: const CustomPaint(size: Size.square(280), painter: _CompassRing()),
                    ),
                    AnimatedRotation(
                      key: const Key('arrow'),
                      turns: (heading != null ? relativeBearing(bearing!, heading) : bearing!) / 360,
                      duration: const Duration(milliseconds: 250),
                      child: const CustomPaint(size: Size.square(280), painter: _Arrow()),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
                Text.rich(
                  key: const Key('distance'),
                  TextSpan(children: [
                    TextSpan(text: formatDistance(distance!).replaceAll(RegExp(r' (m|km)$'), ''), style: AP.monoStyle(64, color: Colors.white)),
                    TextSpan(text: formatDistance(distance).endsWith('km') ? ' km' : ' m', style: AP.monoStyle(28, color: AP.onDarkMuted)),
                  ]),
                ),
                const SizedBox(height: 4),
                Text.rich(TextSpan(children: [
                  TextSpan(text: 'Head ${compassWords[compassPoint(bearing)]} · '),
                  TextSpan(text: '${bearing.round()}°', style: AP.monoStyle(16, color: AP.onDark, weight: FontWeight.w400)),
                  TextSpan(text: ' · ${walkTime(distance)}'),
                ]), style: const TextStyle(color: AP.onDark, fontSize: 16, fontWeight: FontWeight.w700)),
              ],
              if (me != null) ...[
                const SizedBox(height: 18),
                Wrap(spacing: 8, children: [
                  _Chip(dot: me.accuracy <= 10 ? const Color(0xFF5BD18B) : AP.pending, text: 'GPS ±${me.accuracy.round()} m'),
                  _Chip(
                    icon: Icons.explore_outlined,
                    text: heading == null ? 'No compass · north-up' : _compassIsMagnetic ? 'Magnetic, corrected' : 'True north',
                  ),
                ]),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('log-observation'),
                style: FilledButton.styleFrom(backgroundColor: AP.lime, foregroundColor: AP.ink, minimumSize: const Size(0, 58),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                onPressed: _log,
                icon: const Icon(Icons.edit_note, color: AP.ink),
                label: const Text('Log observation'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _DarkButton extends StatelessWidget {
  const _DarkButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: label,
        onPressed: onTap,
        style: IconButton.styleFrom(backgroundColor: AP.night3, fixedSize: const Size(44, 44), disabledBackgroundColor: AP.night2),
        icon: Icon(icon, color: onTap == null ? AP.muted : Colors.white, size: 20),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.icon, this.dot});

  final String text;
  final IconData? icon;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: AP.night2, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          if (icon != null) Icon(icon, size: 13, color: AP.onDark),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: AP.onDark, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _CompassRing extends CustomPainter {
  const _CompassRing();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF10221A));
    canvas.drawCircle(c, r, Paint()..color = AP.nightLine..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawCircle(c, r * 0.72, Paint()..color = AP.night3..style = PaintingStyle.stroke..strokeWidth = 1.5);
    for (var i = 0; i < 72; i++) {
      final major = i % 18 == 0, mid = i % 6 == 0;
      final a = i * 5 * pi / 180;
      final dir = Offset(sin(a), -cos(a));
      final len = major ? 15.0 : mid ? 10.0 : 6.0;
      canvas.drawLine(c + dir * (r - 4), c + dir * (r - 4 - len), Paint()
        ..color = major ? AP.onDarkMuted : mid ? const Color(0xFF4E6B5A) : const Color(0xFF2B4637)
        ..strokeWidth = major ? 2.5 : 1.5);
    }
    const labels = {'N': 0.0, 'E': 90.0, 'S': 180.0, 'W': 270.0};
    labels.forEach((text, deg) {
      final a = deg * pi / 180;
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontFamily: AP.sans, fontSize: text == 'N' ? 16 : 14,
            fontWeight: FontWeight.w800, color: text == 'N' ? const Color(0xFFFF6B4A) : AP.onDarkMuted)),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = c + Offset(sin(a), -cos(a)) * (r - 34);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    });
  }

  @override
  bool shouldRepaint(_CompassRing oldDelegate) => false;
}

class _Arrow extends CustomPainter {
  const _Arrow();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 290; // drawn on the 290-unit design grid
    final path = Path()
      ..moveTo(145 * s, 62 * s)
      ..lineTo(188 * s, 178 * s)
      ..lineTo(145 * s, 156 * s)
      ..lineTo(102 * s, 178 * s)
      ..close();
    canvas.drawPath(path, Paint()..color = AP.lime);
    canvas.drawPath(path, Paint()..color = AP.night..style = PaintingStyle.stroke..strokeWidth = 3..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(Offset(145 * s, 145 * s), 6 * s, Paint()..color = AP.night);
  }

  @override
  bool shouldRepaint(_Arrow oldDelegate) => false;
}
