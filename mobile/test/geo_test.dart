import 'package:agripulse_scout/geo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('distance', () {
    test('one degree of latitude is ~111.2 km', () {
      expect(distanceMeters(52, 5, 53, 5), closeTo(111195, 50));
    });

    test('short field distances are accurate to centimetres', () {
      // 0.001° of latitude ~ 111.2 m
      expect(distanceMeters(52.5400, 5.6030, 52.5410, 5.6030), closeTo(111.2, 0.1));
    });

    test('same point is zero', () => expect(distanceMeters(52.5, 5.6, 52.5, 5.6), 0));
  });

  group('bearing', () {
    test('cardinal directions', () {
      expect(bearingDegrees(52, 5, 53, 5), closeTo(0, 1e-9));
      expect(bearingDegrees(52, 5, 52, 6), closeTo(89.6, 0.1)); // great circle starts just north of east
      expect(bearingDegrees(52, 5, 51, 5), closeTo(180, 1e-9));
      expect(bearingDegrees(52, 5, 52, 4), closeTo(270.4, 0.1));
    });

    test('result is always in [0, 360)', () {
      final b = bearingDegrees(52.54, 5.6031, 52.5401, 5.6030);
      expect(b, inInclusiveRange(0, 359.999));
      expect(b, greaterThan(270));
    });
  });

  group('relativeBearing', () {
    test('target straight ahead', () => expect(relativeBearing(90, 90), 0));
    test('target to the right', () => expect(relativeBearing(100, 90), 10));
    test('wraps through north', () {
      expect(relativeBearing(10, 350), 20);
      expect(relativeBearing(350, 10), -20);
    });
    test('directly behind is +180', () => expect(relativeBearing(270, 90), 180));
  });

  group('declination (WMM-2025)', () {
    final when = DateTime.utc(2026, 6, 1);
    // Reference values from NOAA's calculator for 2026, within the model's ~0.5° uncertainty.
    test('Netherlands is slightly east', () => expect(declinationDegrees(52.54, 5.60, when), closeTo(2.6, 1.0)));
    test('Seattle is strongly east', () => expect(declinationDegrees(47.61, -122.33, when), closeTo(15.0, 1.0)));
    test('Cape Town is strongly west', () => expect(declinationDegrees(-33.92, 18.42, when), closeTo(-26.0, 1.5)));
  });

  group('trueHeading', () {
    test('iOS true heading passes through', () {
      expect(trueHeading(123, isMagnetic: false, lat: 47.61, lon: -122.33), 123);
    });

    test('Android magnetic heading gets declination added', () {
      final h = trueHeading(350, isMagnetic: true, lat: 47.61, lon: -122.33);
      expect(h, closeTo((350 + declinationDegrees(47.61, -122.33)) % 360, 1e-9));
      expect(h, lessThan(10)); // wrapped past north
    });
  });

  test('formatting', () {
    expect(formatDistance(4.26), '4.3 m');
    expect(formatDistance(212.4), '212 m');
    expect(formatDistance(1530), '1.53 km');
    expect(compassPoint(0), 'N');
    expect(compassPoint(44), 'NE');
    expect(compassPoint(359), 'N');
    expect(compassPoint(200), 'S');
  });
}
