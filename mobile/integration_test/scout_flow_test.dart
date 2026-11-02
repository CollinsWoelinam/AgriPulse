// End-to-end scouting flow against a running backend (docker compose up) with a processed field
// and scout@example.com / correct-horse. Run with test_driver/run_ios.sh, which also grants location,
// places the simulator near the field and captures the screenshots requested below.
import 'dart:convert';

import 'package:agripulse_scout/main.dart';
import 'package:agripulse_scout/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

const _email = 'scout@example.com';
const _password = 'correct-horse';

/// Asks the host to capture the simulator screen (flutter's own screenshots come out blank on the iOS
/// simulator): see test_driver/run_ios.sh. Pauses so the capture lands on this frame.
Future<void> shot(WidgetTester tester, String name) async {
  // ignore: avoid_print
  print('SCREENSHOT:$name');
  await settle(tester, 2500);
}

Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      final visible = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>();
      await shot(tester, 'timeout');
      throw TestFailure('Timed out waiting for $finder\nOn screen: ${visible.join(' | ')}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> settle(WidgetTester tester, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder keyStartingWith(String prefix) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scout signs in, saves a field offline, navigates to the next target and logs an observation', (tester) async {
    final services = await Services.init();
    if (services.signedIn) await services.signOut();
    await tester.pumpWidget(ScoutApp(services: services));
    await settle(tester);

    // Sign in
    await tester.enterText(find.byKey(const Key('email')), _email);
    await tester.enterText(find.byKey(const Key('password')), _password);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 800);
    await shot(tester, '01-login');
    await tester.tap(find.byKey(const Key('sign-in')));

    // Fields: save the first field for offline use
    final fieldCard = keyStartingWith('field-');
    await pumpUntil(tester, fieldCard);
    await settle(tester, 500);
    final fieldId = (tester.widget(fieldCard.first).key! as ValueKey<String>).value.substring('field-'.length);
    final download = find.byKey(Key('download-$fieldId'));
    if (download.evaluate().isNotEmpty) await tester.tap(download);
    await pumpUntil(tester, find.byKey(Key('offline-$fieldId')), timeout: const Duration(minutes: 2));
    await pumpUntil(tester, find.byKey(const Key('scout-next')));
    await settle(tester);
    await shot(tester, '02-fields');

    // Field map
    await tester.tap(fieldCard.first);
    await pumpUntil(tester, find.byKey(const Key('target-1')));
    await pumpUntil(tester, find.textContaining('GPS ±'));
    expect(find.text('Saved offline'), findsOneWidget);
    expect(find.text('Offline copy'), findsNothing); // live data loaded, not the fallback
    await settle(tester, 6000); // imagery tiles
    await shot(tester, '03-map');

    // Navigate to the next unscouted target
    final nextRow = find.ancestor(of: find.text('Next up'), matching: keyStartingWith('target-')).first;
    final nextRank = (tester.widget(nextRow).key! as ValueKey<String>).value.substring('target-'.length);
    await tester.tap(nextRow);
    await pumpUntil(tester, find.byKey(const Key('distance')));
    expect(find.text('Target $nextRank of 5'), findsOneWidget);
    await settle(tester);
    await shot(tester, '04-navigate');

    // Log an observation for it
    await tester.tap(find.byKey(const Key('log-observation')));
    await pumpUntil(tester, find.byKey(const Key('location-sub')));
    await tester.tap(find.byKey(const Key('cat-irrigation_failure')));
    final marker = 'integration ${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(find.byKey(const Key('note-text')), 'Dry patch along the headland ($marker)');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 800);
    await shot(tester, '05-observation');
    await tester.tap(find.byKey(const Key('save-note')));

    // Back on the navigate screen, moved on to the following open target
    await pumpUntil(tester, find.text('Observation saved and uploaded.'));
    await pumpUntil(tester, find.byKey(const Key('distance')));
    expect(find.text('Target $nextRank of 5'), findsNothing);
    await settle(tester, 1500);
    await shot(tester, '06-navigate-next');

    // Map shows the target as scouted
    await tester.tap(find.byTooltip('Back'));
    await pumpUntil(tester, find.byKey(const Key('target-1')));
    await settle(tester, 2500);
    await shot(tester, '07-map-after');

    // The server has it, attributed to the scout and linked to the target's zone
    final base = services.serverUrl;
    final login = await http.post(Uri.parse('$base/api/auth/login'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': _email, 'password': _password}));
    final token = jsonDecode(login.body)['token'];
    final res = await http.get(Uri.parse('$base/api/fields/$fieldId/notes'), headers: {'Authorization': 'Bearer $token'});
    final notes = (jsonDecode(res.body) as List).where((n) => (n['note'] as String).contains(marker)).toList();
    expect(notes, hasLength(1));
    expect(notes.single['category'], 'irrigation_failure');
    expect(notes.single['author'], 'Sam Scout');
    expect(notes.single['zone_id'], isNotNull);
    expect(services.sync!.pending, 0);

    // My notes tab lists it as uploaded
    await tester.tap(find.byTooltip('Back'));
    await pumpUntil(tester, find.text('My notes'));
    await tester.tap(find.text('My notes'));
    await pumpUntil(tester, find.textContaining(marker));
    await settle(tester, 1000);
    await shot(tester, '08-my-notes');
  });
}
