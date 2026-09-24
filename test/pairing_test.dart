import 'dart:convert';
import 'dart:io';

import 'package:aniview/pairing.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('phone and TV derive the same code and key, and only that key opens the token', () {
    final phone = PairKeys(), tv = PairKeys();
    final a = phone.agree(tv.publicKey), b = tv.agree(phone.publicKey);
    expect(a.code, b.code);
    expect(a.code, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(unseal(b.key, seal(a.key, 'token')), 'token');

    // A device in the middle ends up with a different code and can't open it.
    final middle = PairKeys();
    final spoofed = phone.agree(middle.publicKey);
    expect(spoofed.code, isNot(b.code));
    expect(() => unseal(b.key, seal(spoofed.key, 'token')), throwsA(anything));
  });

  test(
    'a TV pairs a remote only while waiting, and refuses strangers and replays',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null; // the binding fakes every request otherwise
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      await TvLink.start();
      final base = 'http://127.0.0.1:${TvLink.address!.split(':').last}';
      Future<http.Response> post(String path, Map body) =>
          http.post(Uri.parse('$base$path'), body: jsonEncode(body));

      final phone = PairKeys();
      expect(
        (await post('/pair', {
          'pub': base64.encode(phone.publicKey),
        })).statusCode,
        HttpStatus.forbidden, // no pairing screen open on the TV
      );

      final paired = TvLink.pair();
      final tv = jsonDecode(
        (await post('/pair', {'pub': base64.encode(phone.publicKey)})).body,
      );
      final key = phone.agree(base64.decode(tv['pub'])).key;
      expect(TvLink.code.value, isNotNull);
      final res = await post('/remote', {
        'data': base64.encode(seal(key, jsonEncode({'token': 'abc'}))),
      });
      expect(res.statusCode, 200);
      expect(await paired, 'abc'); // the phone's sign-in rides along
      expect(Settings.remoteKeys, [base64.encode(key)]);

      // Nothing has focus here, so typing is turned away, but only after the press was let in.
      final press = {
        'id': remoteKeyId(key),
        'data': base64.encode(
          seal(
            key,
            jsonEncode({
              'text': 'a',
              't': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
        ),
      };
      expect((await post('/key', press)).statusCode, HttpStatus.conflict);
      expect((await post('/key', press)).statusCode, HttpStatus.badRequest);

      final stranger = PairKeys().agree(PairKeys().publicKey).key;
      expect(
        (await post('/key', {
          ...press,
          'id': remoteKeyId(stranger),
        })).statusCode,
        HttpStatus.forbidden,
      );

      // Every answer says what's playing; typing with no text box focused searches on the TV.
      var sent = DateTime.now().millisecondsSinceEpoch;
      Future<http.Response> send(Map body) => post('/key', {
        'id': remoteKeyId(key),
        'data': base64.encode(seal(key, jsonEncode({...body, 't': ++sent}))),
      });
      String? searched;
      onRemoteSearch = (query) => searched = query;
      addTearDown(() => onRemoteSearch = null);
      nowPlaying.value = (
        title: 'Show',
        episode: 'Episode 3',
        paused: false,
        position: const Duration(seconds: 90),
        duration: const Duration(minutes: 24),
      );
      addTearDown(() => nowPlaying.value = null);
      final state = jsonDecode((await send({'q': 'state'})).body);
      expect(
        (state['playing'], state['episode'], state['position']),
        (true, 'Episode 3', 90000),
      );
      expect((await send({'text': 'frieren'})).statusCode, 200);
      expect(searched, 'frieren');
    },
  );
}
