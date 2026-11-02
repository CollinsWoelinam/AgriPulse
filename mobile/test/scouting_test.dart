import 'package:agripulse_scout/models.dart';
import 'package:agripulse_scout/scouting.dart';
import 'package:agripulse_scout/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

StressTarget target(String id, int rank, {int notes = 0}) => StressTarget(
    zoneId: id, rank: rank, point: const LatLng(52.54, 5.6), rings: const [], meanNdvi: 0.2, areaSqm: 1000, noteCount: notes);

LocalNote note(String? zoneId) => LocalNote(
    id: 'n-$zoneId', fieldId: 'f', zoneId: zoneId, lat: 52.54, lon: 5.6, category: 'weeds', note: '', observedAt: DateTime.utc(2026));

void main() {
  test('first unscouted target in priority order is next', () {
    final s = targetStates([target('a', 1, notes: 2), target('b', 2), target('c', 3)], []);
    expect(s, {'a': TargetState.scouted, 'b': TargetState.next, 'c': TargetState.open});
  });

  test("this phone's unsynced notes count as scouted", () {
    final s = targetStates([target('a', 1), target('b', 2)], [note('a'), note(null)]);
    expect(s, {'a': TargetState.scouted, 'b': TargetState.next});
  });

  test('all scouted means no next', () {
    final s = targetStates([target('a', 1, notes: 1), target('b', 2)], [note('b')]);
    expect(s.values, everyElement(TargetState.scouted));
  });

  test('walk time', () {
    expect(walkTime(40), 'under a minute');
    expect(walkTime(102), 'about 1 min walk');
    expect(walkTime(780), 'about 10 min walk');
  });

  test('NDVI colours match the shared ramp end points', () {
    expect(ndviColor(-1).toARGB32(), 0xFFA50026);
    expect(ndviColor(0.9).toARGB32(), 0xFF006837);
    expect(ndviColor(2).toARGB32(), 0xFF006837);
  });
}
