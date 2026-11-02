// End-to-end scouting flow against a running backend (docker compose up) with a processed field
// and scout@example.com / correct-horse. Run on a simulator with location granted and set near the field:
//
//   flutter drive --driver test_driver/integration_test.dart --target integration_test/scout_flow_test.dart
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scout signs in, saves a field offline, navigates to a target and logs an observation', (tester) async {
    final services = await Services.init();
    if (services.signedIn) await services.signOut();
    await tester.pumpWidget(ScoutApp(services: services));
    await settle(tester);

    // Sign in
    await tester.enterText(find.byKey(const Key('email')), _email);
    await tester.enterText(find.byKey(const Key('password')), _password);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 500);
    await shot(tester, '01-login');
    await tester.tap(find.byKey(const Key('sign-in')));

    // Fields list, then save the first field for offline use
    final fieldTile = find.byWidgetPredicate((w) => w is ListTile && '${w.key}'.contains("'field-"));
    await pumpUntil(tester, fieldTile);
    await settle(tester, 500);
    final fieldId = (tester.widget<ListTile>(fieldTile.first).key as ValueKey<String>).value.substring('field-'.length);
    final download = find.byKey(Key('download-$fieldId'));
    if (find.descendant(of: download, matching: find.byIcon(Icons.offline_pin)).evaluate().isEmpty) {
      await tester.tap(download);
    }
    await pumpUntil(tester, find.descendant(of: download, matching: find.byIcon(Icons.offline_pin)),
        timeout: const Duration(minutes: 2));
    await settle(tester);
    await shot(tester, '02-fields');

    // Field map with targets
    await tester.tap(fieldTile.first);
    await pumpUntil(tester, find.byKey(const Key('target-1')));
    await pumpUntil(tester, find.textContaining('GPS ±'));
    expect(find.textContaining('Map saved offline'), findsOneWidget);
    expect(find.textContaining('offline copy'), findsNothing); // live data loaded, not the fallback
    await settle(tester, 6000); // imagery tiles
    await shot(tester, '03-map');

    // Navigate to the most stressed target
    await tester.tap(find.byKey(const Key('target-1')));
    await pumpUntil(tester, find.byKey(const Key('distance')));
    await settle(tester);
    await shot(tester, '04-navigate');

    // Log an observation for that target
    await tester.tap(find.byKey(const Key('log-observation')));
    await pumpUntil(tester, find.textContaining('Accuracy ±'));
    await tester.tap(find.byKey(const Key('cat-nitrogen_deficiency')));
    final marker = 'integration ${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(find.byKey(const Key('note-text')), 'Pale lower leaves across the patch ($marker)');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 800);
    await shot(tester, '05-observation');
    await tester.tap(find.byKey(const Key('save-note')));
    await pumpUntil(tester, find.text('Observation saved and uploaded.'));
    await settle(tester, 2500);
    await shot(tester, '06-map-after-save');

    // The server has it, attributed to the scout and linked to the target's zone
    final base = services.serverUrl;
    final login = await http.post(Uri.parse('$base/api/auth/login'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': _email, 'password': _password}));
    final token = jsonDecode(login.body)['token'];
    final res = await http.get(Uri.parse('$base/api/fields/$fieldId/notes'), headers: {'Authorization': 'Bearer $token'});
    final notes = (jsonDecode(res.body) as List).where((n) => (n['note'] as String).contains(marker)).toList();
    expect(notes, hasLength(1));
    expect(notes.single['category'], 'nitrogen_deficiency');
    expect(notes.single['author'], 'Sam Scout');
    expect(notes.single['zone_id'], isNotNull);
    expect(services.sync!.pending, 0);
  });
}
