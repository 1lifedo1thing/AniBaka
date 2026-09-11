import 'dart:async';
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Party extends WatchPartyService {
  Party(AccountSession session) : super(session: session);
  final joined = <String>[];
  @override
  Future<void> joinInvite(String code, {String? nickname}) async {
    joined.add(code);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Party party;
  late WatchPartyLinks links;
  late StreamController<Uri> stream;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    party = Party(AccountSession(prefs, refreshTokens: (_) async => null));
    stream = StreamController<Uri>();
    links = WatchPartyLinks(party, incoming: stream.stream)..initializeLinks();
  });
  tearDown(() async {
    await links.close();
    await stream.close();
    await party.close();
  });
  test('a cold link waits for navigation readiness', () async {
    stream.add(Uri.parse('anibaka://watch/invite-1'));
    await Future<void>.delayed(Duration.zero);
    expect(party.joined, isEmpty);
    links.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(party.joined, ['invite-1']);
  });
  test('closing cancels queued and future links', () async {
    stream.add(Uri.parse('anibaka://watch/invite-1'));
    await links.close();
    links.markReady();
    stream.add(Uri.parse('anibaka://watch/invite-2'));
    await Future<void>.delayed(Duration.zero);
    expect(party.joined, isEmpty);
  });
}
