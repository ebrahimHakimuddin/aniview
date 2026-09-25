import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' hide Padding, State;

import 'anilist.dart';
import 'settings.dart';
import 'states.dart';
import 'platform.dart';
import 'player.dart' show formatDuration;
import 'tv.dart';
import 'ui.dart';

/// Pairing a phone with a TV over the local network: one pairing makes the phone a remote and, when the phone
/// is signed in and the TV isn't, signs the TV in to the same AniList account.
///
/// The phone finds the TV with a UDP broadcast (or the address typed from the TV screen), then the two run an
/// ECDH key exchange over HTTP. Both show a 6-digit code derived from the shared secret; the user checks they
/// match, which rules out another device on the network sitting in the middle. Only then does the phone send
/// its AniList token, encrypted with AES-GCM under the shared key.
const _discoveryPort = 47811;
const _hello = 'aniview-pair';

final _curve = ECDomainParameters('prime256v1');

SecureRandom _secureRandom() {
  final random = Random.secure();
  return FortunaRandom()..seed(
    KeyParameter(
      Uint8List.fromList([for (var i = 0; i < 32; i++) random.nextInt(256)]),
    ),
  );
}

Uint8List _sha256(String label, Uint8List data) => SHA256Digest().process(
  Uint8List.fromList([...utf8.encode(label), ...data]),
);

/// One side's ephemeral key pair for a pairing attempt.
class PairKeys {
  PairKeys() {
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(ECKeyGeneratorParameters(_curve), _secureRandom()),
      );
    final pair = generator.generateKeyPair();
    _private = pair.privateKey;
    publicKey = pair.publicKey.Q!.getEncoded(false);
  }

  late final ECPrivateKey _private;
  late final Uint8List publicKey;

  /// The code both screens show and the AES key, from the other side's public key.
  ({String code, Uint8List key}) agree(Uint8List otherPublic) {
    final point = _curve.curve.decodePoint(otherPublic);
    if (point == null || point.isInfinity) {
      throw const FormatException('Bad key');
    }
    final secret = (ECDHBasicAgreement()..init(_private))
        .calculateAgreement(ECPublicKey(point, _curve))
        .toRadixString(16)
        .padLeft(64, '0');
    final shared = Uint8List.fromList(utf8.encode(secret));
    final digits =
        ByteData.sublistView(_sha256('code', shared)).getUint32(0) % 1000000;
    final code = digits.toString().padLeft(6, '0');
    return (
      code: '${code.substring(0, 3)} ${code.substring(3)}',
      key: _sha256('key', shared),
    );
  }
}

GCMBlockCipher _gcm(bool encrypt, Uint8List key, Uint8List nonce) =>
    GCMBlockCipher(AESEngine())..init(
      encrypt,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );

/// Nonce followed by the AES-GCM ciphertext of [text].
Uint8List seal(Uint8List key, String text) {
  final nonce = _secureRandom().nextBytes(12);
  return Uint8List.fromList([
    ...nonce,
    ..._gcm(true, key, nonce).process(utf8.encode(text)),
  ]);
}

/// Opens [seal]'s output; throws when it was made with another key or tampered with.
String unseal(Uint8List key, Uint8List sealed) => utf8.decode(
  _gcm(false, key, sealed.sublist(0, 12)).process(sealed.sublist(12)),
);

// ───────────────────────────── TV side ─────────────────────────────

/// The TV's end of the Wi-Fi link to phones, running while the app is open on a TV. It answers phones looking
/// for a TV, pairs with one while [TvPairScreen] is open, and presses the keys that paired remotes send.
class TvLink {
  static HttpServer? _server;

  /// "192.168.1.20:40123", for typing into a phone that can't find the TV.
  static String? address;

  /// The code to compare with the phone's, once one has started pairing.
  static final code = ValueNotifier<String?>(null);

  static ({String code, Uint8List key})? _agreed;
  static Completer<String?>? _paired; // while a pairing screen is open
  static final _lastPress = <String, int>{};

  static Future<void> start() async {
    if (_server != null) return;
    try {
      final server = _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        0,
      );
      server.listen(_handle);
      final ip = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .firstOrNull;
      address = '${ip?.address ?? '?'}:${server.port}';
      final device = await AndroidApp.device().catchError((Object _) => null);
      // Answer phones looking for a TV; without it (port taken, broadcasts blocked) the address still works.
      final discovery = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
      );
      discovery.listen((event) {
        final packet = discovery.receive();
        if (event != RawSocketEvent.read || packet == null) return;
        if (utf8.decode(packet.data, allowMalformed: true) != _hello) return;
        discovery.send(
          utf8.encode(
            jsonEncode({
              'name': device?.split('; ').last ?? 'Android TV',
              'port': server.port,
              'id': Settings.installId,
            }),
          ),
          packet.address,
          packet.port,
        );
      });
    } catch (_) {}
  }

  /// Waits for a phone to pair as a remote; completes with its AniList token, or null when it isn't signed in.
  /// Phones can only pair while this is waiting.
  static Future<String?> pair() {
    stopPairing();
    return (_paired = Completer()).future;
  }

  static void stopPairing() {
    _agreed = null;
    _paired = null;
    code.value = null;
  }

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      final agreed = _agreed;
      switch (request.uri.path) {
        case '/pair'
            when _paired != null: // a new attempt replaces any earlier one
          final keys = PairKeys();
          final agreed = _agreed = keys.agree(base64.decode(body['pub']));
          code.value = agreed.code;
          response.write(jsonEncode({'pub': base64.encode(keys.publicKey)}));
        case '/remote' when _paired != null && agreed != null:
          // Opening it proves the phone holds the key the codes vouched for.
          final sent = jsonDecode(
            unseal(agreed.key, base64.decode(body['data'])),
          ) as Map;
          Settings.remoteKeys = [
            ...Settings.remoteKeys,
            base64.encode(agreed.key),
          ];
          response.write(jsonEncode({'id': Settings.installId}));
          _paired?.complete(sent['token'] as String?);
          stopPairing();
        case '/key':
          final key = Settings.remoteKeys
              .map(base64.decode)
              .where((k) => remoteKeyId(k) == body['id'])
              .firstOrNull;
          if (key == null) {
            response.statusCode = HttpStatus.forbidden;
            break;
          }
          final press =
              jsonDecode(unseal(key, base64.decode(body['data']))) as Map;
          // Each press is sent once: a replayed or stale one is refused.
          final at = press['t'] as int;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (at <= (_lastPress[body['id']] ?? 0) ||
              (now - at).abs() > const Duration(minutes: 5).inMilliseconds) {
            throw const FormatException();
          }
          _lastPress[body['id']] = at;
          switch (press) {
            case {'q': 'state'}:
              break; // just the answer below
            case {'seek': final int ms}:
              onRemoteSeek?.call(Duration(milliseconds: ms));
            case {'text': final String text}:
              // Into the TV's focused text box, else a search on the TV.
              if (!typeText(text)) {
                if (onRemoteSearch case final search?) {
                  search(text);
                } else {
                  response.statusCode = HttpStatus.conflict;
                }
              }
            case {'k': 'search'}:
              onRemoteSearch?.call(null);
            case {'k': final String key}:
              if (key != 'back' && !remoteKeys.containsKey(key)) {
                throw const FormatException();
              }
              await pressKey(key, hold: press['hold'] == true);
            default:
              throw const FormatException();
          }
          // What's playing, so the phone can show playback controls.
          final np = nowPlaying.value;
          response.write(
            jsonEncode({
              'playing': np != null,
              if (np != null) ...{
                'title': np.title,
                'episode': np.episode,
                'paused': np.paused,
                'position': np.position.inMilliseconds,
                'duration': np.duration.inMilliseconds,
              },
            }),
          );
        default:
          response.statusCode = HttpStatus.forbidden;
      }
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
    }
    await response.close();
  }
}

/// Names a remote's key without giving it away.
String remoteKeyId(Uint8List key) =>
    base64Url.encode(_sha256('id', key).sublist(0, 9));

/// Waits for a phone to pair as a remote, which also signs this TV in when the phone is signed in and the TV
/// isn't. "Sign in on this TV" pops with [signInHere] to fall back to the web sign-in.
class TvPairScreen extends StatefulWidget {
  const TvPairScreen({super.key});

  static const signInHere = '';

  @override
  State<TvPairScreen> createState() => _TvPairScreenState();
}

class _TvPairScreenState extends State<TvPairScreen> {
  @override
  void initState() {
    super.initState();
    TvLink.pair().then((token) async {
      final signIn = token != null && AniList.token == null;
      if (signIn) await AniList.useToken(token);
      if (!mounted) return;
      showSuccess(
        context,
        signIn
            ? 'Paired, and signed in with your phone'
            : 'Your phone is now a remote',
      );
      Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    TvLink.stopPairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paired = Settings.remoteKeys.length;
    final signedIn = AniList.token != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Pair your phone')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.phonelink_rounded,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              const Text(
                'Pair your phone',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'On your phone, on the same Wi-Fi, open AniView and go to\nSettings → TV remote.'
                '${signedIn ? '' : ' It becomes a remote and signs this TV in.'}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 24),
              const _PairingCode(),
              if (!signedIn) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, TvPairScreen.signInHere),
                  child: const Text('Sign in on this TV instead'),
                ),
              ],
              if (paired > 0) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() => Settings.remoteKeys = []),
                  child: Text(
                    'Unpair ${paired == 1 ? 'the paired phone' : 'all $paired paired phones'}',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The pairing code once a phone has started, and the address to type when it can't find the TV.
class _PairingCode extends StatelessWidget {
  const _PairingCode();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: TvLink.code,
    builder: (context, code, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (code != null) ...[
          const Text('Check that your phone shows'),
          const SizedBox(height: 8),
          Text(
            code,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              letterSpacing: 6,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ] else
          const CircularProgressIndicator(),
        const SizedBox(height: 24),
        if (TvLink.address case final address?)
          Text(
            "Phone can't find this TV? Enter $address",
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
      ],
    ),
  );
}

// ───────────────────────────── Phone side ─────────────────────────────

typedef FoundTv = ({String address, String name, String? id});

/// TVs with AniView open on this network, as they answer a broadcast.
Stream<FoundTv> findTvs() {
  final found = StreamController<FoundTv>();
  () async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..broadcastEnabled = true;
      socket.listen((event) {
        final packet = socket.receive();
        if (event != RawSocketEvent.read || packet == null) return;
        try {
          final reply = jsonDecode(utf8.decode(packet.data)) as Map;
          found.add((
            address: '${packet.address.address}:${reply['port']}',
            name: reply['name'] as String,
            id: reply['id'] as String?,
          ));
        } catch (_) {} // not a TV's answer
      });
      for (var i = 0; i < 3; i++) {
        socket.send(
          utf8.encode(_hello),
          InternetAddress('255.255.255.255'),
          _discoveryPort,
        );
        await Future.delayed(const Duration(milliseconds: 700));
      }
      socket.close();
    } catch (_) {}
    await found.close();
  }();
  return found.stream;
}

/// Starts pairing with the TV at [base] and asks whether both screens show the same code; null when they don't.
Future<({String code, Uint8List key})?> _handshake(
  BuildContext context,
  String base, {
  required String confirm,
}) async {
  final keys = PairKeys();
  final res = await http
      .post(
        Uri.parse('$base/pair'),
        body: jsonEncode({'pub': base64.encode(keys.publicKey)}),
      )
      .timeout(const Duration(seconds: 8));
  if (res.statusCode != 200) {
    throw Exception(
      "The TV isn't waiting to pair. Open the pairing screen on it first",
    );
  }
  final agreed = keys.agree(
    base64.decode((jsonDecode(res.body) as Map)['pub']),
  );
  if (!context.mounted) return null;
  final same = await showDialog<bool>(
    context: context,
    builder: (context) => PanelDialog(
      title: const Text('Does your TV show this code?'),
      content: Text(
        agreed.code,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  if (same == true) return agreed;
  if (context.mounted) showError(context, 'Not paired: the codes must match');
  return null;
}

/// This phone as a remote for a TV running AniView: a D-pad, Back, playback keys and typing into the TV's
/// text boxes. Pairs once per TV, which also signs the TV in when this phone is signed in, then finds it again
/// by its id.
class PhoneRemoteScreen extends StatefulWidget {
  const PhoneRemoteScreen({super.key});

  @override
  State<PhoneRemoteScreen> createState() => _PhoneRemoteScreenState();
}

class _PhoneRemoteScreenState extends State<PhoneRemoteScreen> {
  final found = <String, FoundTv>{}; // by address
  final manual = TextEditingController(), typed = TextEditingController();
  final client = http.Client();
  String? tv; // the paired TV's id being controlled
  bool scanning = false, pairing = false;
  int _sent = 0;

  /// What the TV said it's playing, from its last answer; null when nothing is.
  Map? playing;

  /// Asks the TV what it's playing every couple of seconds, for the playback controls.
  late final Timer _poll = Timer.periodic(
    const Duration(seconds: 2),
    (_) => _send(const {'q': 'state'}, quiet: true),
  );
  Timer? _typing;

  Map<String, dynamic> get paired => Settings.tvRemotes;

  @override
  void initState() {
    super.initState();
    tv = paired.keys.firstOrNull;
    _scan();
    _poll;
  }

  @override
  void dispose() {
    _poll.cancel();
    _typing?.cancel();
    manual.dispose();
    typed.dispose();
    client.close();
    super.dispose();
  }

  /// Looks for TVs, and keeps each paired one's address current (it changes when the app restarts).
  Future<void> _scan() async {
    setState(() {
      scanning = true;
      found.clear();
    });
    await for (final found in findTvs()) {
      if (!mounted) return;
      final id = found.id;
      if (id != null && paired[id] != null) {
        Settings.tvRemotes = {
          ...paired,
          id: {...paired[id], 'address': found.address},
        };
      }
      setState(() => this.found[found.address] = found);
    }
    if (mounted) setState(() => scanning = false);
  }

  Future<void> _pair(String address) async {
    setState(() => pairing = true);
    try {
      final base = 'http://${address.trim()}';
      final token = AniList.token;
      final agreed = await _handshake(
        context,
        base,
        confirm: token == null ? 'Yes, pair' : 'Yes, pair and sign in',
      );
      if (agreed == null) return;
      final res = await client
          .post(
            Uri.parse('$base/remote'),
            body: jsonEncode({
              'data': base64.encode(
                seal(agreed.key, jsonEncode({'token': ?token})),
              ),
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final id = (jsonDecode(res.body) as Map)['id'] as String;
      Settings.tvRemotes = {
        ...paired,
        id: {
          'key': base64.encode(agreed.key),
          'name': found[address.trim()]?.name ?? 'TV',
          'address': address.trim(),
        },
      };
      if (mounted) setState(() => tv = id);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => pairing = false);
    }
  }

  /// Sends one press ({k: up|down|…, hold?} or {text}); each carries a newer time so it can't be replayed.
  /// Sends one press or request to the TV and keeps what it says it's playing. [quiet] ones (status checks)
  /// don't buzz or complain when the TV can't be reached.
  Future<void> _send(Map<String, Object> press, {bool quiet = false}) async {
    final saved = paired[tv];
    if (saved == null) return;
    if (!quiet) HapticFeedback.selectionClick();
    final key = base64.decode(saved['key']);
    _sent = max(DateTime.now().millisecondsSinceEpoch, _sent + 1);
    try {
      final res = await client
          .post(
            Uri.parse('http://${saved['address']}/key'),
            body: jsonEncode({
              'id': remoteKeyId(key),
              'data': base64.encode(
                seal(key, jsonEncode({...press, 't': _sent})),
              ),
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      switch (res.statusCode) {
        case HttpStatus.ok:
          final state = jsonDecode(res.body) as Map;
          setState(() => playing = state['playing'] == true ? state : null);
        case HttpStatus.forbidden: // unpaired on the TV
          _forget();
          showError(context, 'The TV forgot this phone. Pair again');
        case HttpStatus.conflict:
          showError(context, 'Open AniView\'s home on the TV to search');
      }
    } catch (_) {
      if (!mounted || quiet) return;
      showError(
        context,
        "Can't reach ${saved['name']}. Is AniView open on it?",
      );
      if (!scanning) _scan();
    }
  }

  void _forget() => setState(() {
    Settings.tvRemotes = {...paired}..remove(tv);
    tv = paired.keys.firstOrNull;
  });

  @override
  Widget build(BuildContext context) {
    final saved = paired[tv];
    return Scaffold(
      appBar: AppBar(
        title: Text(saved == null ? 'TV remote' : saved['name'] as String),
        bottom: scanning || pairing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: [
          if (saved != null)
            MoreMenu([
              for (final MapEntry(key: id, value: other) in paired.entries)
                if (id != tv)
                  (
                    icon: Icons.tv_rounded,
                    label: 'Switch to ${other['name']}',
                    onTap: () => setState(() => tv = id),
                    destructive: false,
                  ),
              (
                icon: Icons.add_link_rounded,
                label: 'Pair another TV',
                onTap: () => setState(() => tv = null),
                destructive: false,
              ),
              (
                icon: Icons.link_off_rounded,
                label: 'Forget this TV',
                onTap: _forget,
                destructive: true,
              ),
            ]),
        ],
      ),
      body: saved == null ? _pairing() : _remote(),
    );
  }

  Widget _pairing() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'On the TV, open AniView and choose Sign in, or Settings → Phone remote. Keep both on the same Wi-Fi.'
        '${AniList.token == null ? '' : ' Pairing also signs the TV in as you, if it isn\'t already.'}',
        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
      ),
      const SizedBox(height: 16),
      for (final tv in found.values)
        ListTile(
          leading: const Icon(Icons.tv_rounded),
          title: Text(tv.name),
          subtitle: Text(tv.address),
          onTap: pairing ? null : () => _pair(tv.address),
        ),
      if (found.isEmpty && !scanning)
        const ListTile(
          leading: Icon(Icons.search_off_rounded),
          title: Text('No TV found'),
          subtitle: Text('Enter the address shown on the TV instead'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: scanning ? null : _scan,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Search again'),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: manual,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: pairing ? null : _pair,
        decoration: InputDecoration(
          labelText: 'TV address',
          hintText: '192.168.1.20:40123',
          suffixIcon: IconButton(
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: pairing ? null : () => _pair(manual.text),
          ),
        ),
      ),
    ],
  );

  /// Typed text searches on the TV as it's typed, once typing pauses.
  void _typed(String text) {
    _typing?.cancel();
    _typing = Timer(
      const Duration(milliseconds: 500),
      () => _send({'text': text}),
    );
  }

  Widget _remote() {
    // With the keyboard up there's no room for the D-pad, and typing is all that's going on.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    final now = playing;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          children: [
            if (now != null) _nowPlaying(now),
            if (!typing) ...[
              const Spacer(),
              _dpad(),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _button('back', Icons.arrow_back_rounded, 'Back'),
                  _button('rewind', Icons.fast_rewind_rounded, 'Rewind'),
                  _button(
                    'playpause',
                    now?['paused'] == false
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    'Play / pause',
                  ),
                  _button(
                    'forward',
                    Icons.fast_forward_rounded,
                    'Fast forward',
                  ),
                  if (now != null)
                    _button('next', Icons.skip_next_rounded, 'Next episode'),
                ],
              ),
              const Spacer(),
            ],
            // Searching makes no sense mid-episode.
            if (now == null)
              TextField(
                controller: typed,
                textInputAction: TextInputAction.search,
                // Opens Search on the TV, ready for what's typed.
                onTap: () => _send(const {'k': 'search'}),
                onChanged: _typed,
                onSubmitted: (value) {
                  _typing?.cancel();
                  _send({'text': value});
                },
                decoration: InputDecoration(
                  hintText: 'Search on the TV',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.send_rounded),
                    onPressed: () => _send({'text': typed.text}),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The episode playing on the TV, with a seek bar.
  Widget _nowPlaying(Map now) {
    final text = Theme.of(context).textTheme;
    final duration = (now['duration'] as int? ?? 0).toDouble();
    final position = (now['position'] as int? ?? 0).toDouble();
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Now playing',
              style: text.labelMedium?.copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 4),
            Text(
              now['title'] ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleMedium,
            ),
            Text(
              now['episode'] ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (duration > 0)
              Slider(
                max: duration,
                value: position.clamp(0, duration),
                onChanged: (v) => setState(() => now['position'] = v.round()),
                onChangeEnd: (v) => _send({'seek': v.round()}),
              ),
            if (duration > 0)
              Row(
                children: [
                  Text(
                    formatDuration(Duration(milliseconds: position.round())),
                    style: text.bodySmall,
                  ),
                  const Spacer(),
                  Text(
                    formatDuration(Duration(milliseconds: duration.round())),
                    style: text.bodySmall,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _button(String key, IconData icon, String label) =>
      IconButton.filledTonal(
        tooltip: label,
        iconSize: 28,
        padding: const EdgeInsets.all(16),
        onPressed: () => _send({'k': key}),
        icon: Icon(icon),
      );

  Widget _dpad() {
    Widget arrow(String key, IconData icon, Alignment at) => Align(
      alignment: at,
      child: IconButton(
        tooltip: key,
        iconSize: 40,
        padding: const EdgeInsets.all(16),
        onPressed: () => _send({'k': key}),
        icon: Icon(icon),
      ),
    );
    return SizedBox.square(
      dimension: 264,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surfaceContainerHigh,
        ),
        child: Stack(
          children: [
            arrow('up', Icons.keyboard_arrow_up_rounded, Alignment.topCenter),
            arrow(
              'down',
              Icons.keyboard_arrow_down_rounded,
              Alignment.bottomCenter,
            ),
            arrow(
              'left',
              Icons.keyboard_arrow_left_rounded,
              Alignment.centerLeft,
            ),
            arrow(
              'right',
              Icons.keyboard_arrow_right_rounded,
              Alignment.centerRight,
            ),
            Center(
              child: SizedBox.square(
                dimension: 96,
                // Holding OK long-presses on the TV too, for episode and history actions.
                child: FilledButton(
                  style: FilledButton.styleFrom(shape: const CircleBorder()),
                  onPressed: () => _send({'k': 'ok'}),
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    _send({'k': 'ok', 'hold': true});
                  },
                  child: const Text('OK'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
