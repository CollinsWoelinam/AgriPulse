import 'models.dart';
import 'ui/theme.dart';

/// Scouted = any server-side note on the zone (any scout) or one of this phone's notes, synced or not.
/// The first unscouted target in priority order is "next".
Map<String, TargetState> targetStates(List<StressTarget> targets, List<LocalNote> localNotes) {
  final noted = {for (final n in localNotes) if (n.zoneId != null) n.zoneId};
  String? next;
  return {
    for (final t in targets)
      t.zoneId: () {
        if (t.noteCount > 0 || noted.contains(t.zoneId)) return TargetState.scouted;
        next ??= t.zoneId;
        return t.zoneId == next ? TargetState.next : TargetState.open;
      }(),
  };
}

/// About 1.3 m/s over rough field ground.
String walkTime(double meters) {
  final seconds = meters / 1.3;
  return seconds < 60 ? 'under a minute' : 'about ${(seconds / 60).round()} min walk';
}

const compassWords = {'N': 'north', 'NE': 'northeast', 'E': 'east', 'SE': 'southeast',
    'S': 'south', 'SW': 'southwest', 'W': 'west', 'NW': 'northwest'};
