import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../geo.dart';
import '../location.dart';
import '../models.dart';

/// Arrow-and-distance guidance to one stress target.
class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key, required this.target, required this.onLogObservation});

  final StressTarget target;
  final Future<void> Function() onLogObservation;

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  Position? _me;
  double? _compass; // raw platform heading
  String? _locationProblem;
  StreamSubscription<Position>? _positions;
  StreamSubscription<CompassEvent>? _headings;

  // iOS reports CLHeading.trueHeading; Android's rotation vector is magnetic.
  static final bool _compassIsMagnetic = Platform.isAndroid;
  static const _arrivalRadiusM = 10.0;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.target;
    final me = _me;

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
      // No text input here; without this the keyboard of the note screen pushed on top squeezes this layout.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text('Target ${t.rank}')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text('NDVI ${t.meanNdvi.toStringAsFixed(2)} · ${(t.areaSqm / 10000).toStringAsFixed(2)} ha',
                  style: theme.textTheme.titleMedium),
              const Spacer(),
              if (me == null)
                Text(_locationProblem ?? 'Waiting for GPS…', textAlign: TextAlign.center, style: theme.textTheme.titleLarge)
              else if (arrived)
                Column(children: [
                  Icon(Icons.where_to_vote, size: 120, color: theme.colorScheme.primary),
                  Text("You're at the target", key: const Key('arrived'), style: theme.textTheme.headlineSmall),
                ])
              else
                _Arrow(
                  // With a compass the arrow is relative to where the phone points; without one it is a
                  // north-up bearing, and a fixed N marker makes that explicit.
                  angle: heading != null ? relativeBearing(bearing!, heading) : bearing!,
                  northUp: heading == null,
                ),
              const SizedBox(height: 24),
              if (distance != null && !arrived) ...[
                Text(formatDistance(distance), key: const Key('distance'), style: theme.textTheme.displayMedium),
                Text('${bearing!.round()}° ${compassPoint(bearing)}', style: theme.textTheme.titleMedium),
              ],
              if (me != null) ...[
                const SizedBox(height: 8),
                Text(
                  'GPS ±${me.accuracy.round()} m'
                  '${heading == null ? ' · no compass: arrow is north-up' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('log-observation'),
                  onPressed: () async {
                    await widget.onLogObservation();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Log observation'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.angle, required this.northUp});

  final double angle; // degrees clockwise
  final bool northUp;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 0.3), width: 3)),
          ),
          if (northUp)
            const Positioned(top: 6, child: Text('N', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
          AnimatedRotation(
            key: const Key('arrow'),
            turns: angle / 360,
            duration: const Duration(milliseconds: 250),
            child: Icon(Icons.navigation, size: 150, color: color),
          ),
        ],
      ),
    );
  }
}
