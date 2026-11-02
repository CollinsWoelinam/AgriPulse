import 'dart:math';

import 'package:geomag/geomag.dart';

const _earthRadiusM = 6371000.0;
double _rad(double deg) => deg * pi / 180.0;

/// Great-circle distance in meters (haversine).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return _earthRadiusM * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// Initial bearing from point 1 to point 2, degrees clockwise from true north, in [0, 360).
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  final dLon = _rad(lon2 - lon1);
  final y = sin(dLon) * cos(_rad(lat2));
  final x = cos(_rad(lat1)) * sin(_rad(lat2)) - sin(_rad(lat1)) * cos(_rad(lat2)) * cos(dLon);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

/// Angle to rotate an "ahead" arrow so it points at the target, in (-180, 180].
/// Both inputs are degrees from true north.
double relativeBearing(double targetBearing, double trueHeading) {
  final d = (targetBearing - trueHeading) % 360;
  return d > 180 ? d - 360 : d;
}

/// Magnetic declination (degrees, east positive) from the World Magnetic Model 2025.
double declinationDegrees(double lat, double lon, [DateTime? when]) =>
    GeoMag().calculate(lat, lon, 0, when ?? DateTime.now()).dec;

/// Turns a compass reading into a true heading. iOS already reports true heading
/// (CLHeading.trueHeading); Android's rotation-vector sensor reports magnetic heading.
double trueHeading(double compassHeading, {required bool isMagnetic, required double lat, required double lon}) {
  final h = isMagnetic ? compassHeading + declinationDegrees(lat, lon) : compassHeading;
  return (h % 360 + 360) % 360;
}

String formatDistance(double meters) {
  if (meters < 10) return '${meters.toStringAsFixed(1)} m';
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 2 : 1)} km';
}

const _compassPoints = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
String compassPoint(double bearing) => _compassPoints[((bearing % 360) / 45).round() % 8];
