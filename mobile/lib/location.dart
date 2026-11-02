import 'package:geolocator/geolocator.dart';

/// Returns null when location is usable, otherwise a message the scout can act on.
Future<String?> ensureLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) return 'Location is turned off on this device.';
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
  return switch (perm) {
    LocationPermission.always || LocationPermission.whileInUse => null,
    LocationPermission.deniedForever => 'Location access is blocked. Allow it in Settings to navigate.',
    _ => 'Location access is needed to navigate to targets.',
  };
}

/// Live positions, starting with the last known fix. Geolocator shares one native stream, so a screen
/// that subscribes later would otherwise see nothing until the phone moves past the distance filter;
/// a scout standing still would be stuck on "waiting for GPS".
Stream<Position> positionStream() async* {
  final last = await Geolocator.getLastKnownPosition();
  if (last != null) yield last;
  yield* Geolocator.getPositionStream(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1),
  );
}
