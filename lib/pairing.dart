import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' hide State;

import 'anilist.dart';
import 'states.dart';

/// Signing a TV in from a phone that's already signed in, over the local network.
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

/// Waits for a phone to sign this TV in; pops with the AniList token. "Sign in on this TV" pops with
/// [signInHere] to fall back to the web sign-in.
class TvPairScreen extends StatefulWidget {
  const TvPairScreen({super.key});

  static const signInHere = '';

  @override
  State<TvPairScreen> createState() => _TvPairScreenState();
}

class _TvPairScreenState extends State<TvPairScreen> {
  HttpServer? _server;
  RawDatagramSocket? _discovery;
  String? address, code;
  ({String code, Uint8List key})? _agreed;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
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
      final device = await const MethodChannel('aniview/app')
          .invokeMethod<String>('device')
          .catchError((Object _) => null);
      if (mounted) {
        setState(() => address = '${ip?.address ?? '?'}:${server.port}');
      }
      // Answer phones looking for a TV; without it (port taken, broadcasts blocked) the address still works.
      final discovery = _discovery = await RawDatagramSocket.bind(
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
            }),
          ),
          packet.address,
          packet.port,
        );
      });
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      switch (request.uri.path) {
        case '/pair': // a new attempt replaces any earlier one
          final keys = PairKeys();
          final agreed = _agreed = keys.agree(base64.decode(body['pub']));
          if (mounted) setState(() => code = agreed.code);
          response.write(jsonEncode({'pub': base64.encode(keys.publicKey)}));
        case '/token':
          final token = unseal(_agreed!.key, base64.decode(body['data']));
          await response.close();
          if (mounted) Navigator.pop(context, token);
          return;
        default:
          response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
    }
    await response.close();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _discovery?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in with AniList')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phonelink_rounded, size: 56, color: primary),
              const SizedBox(height: 16),
              const Text(
                'Sign in with your phone',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'On a phone signed in to AniView, on the same Wi-Fi, open\nSettings → Sign in a TV',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 24),
              if (code != null) ...[
                const Text('Check that your phone shows'),
                const SizedBox(height: 8),
                Text(
                  code!,
                  style: TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 6,
                    color: primary,
                  ),
                ),
              ] else
                const CircularProgressIndicator(),
              const SizedBox(height: 24),
              if (address != null)
                Text(
                  "Phone can't find this TV? Enter $address",
                  style: const TextStyle(fontSize: 13, color: Colors.white54),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, TvPairScreen.signInHere),
                child: const Text('Sign in on this TV instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Phone side ─────────────────────────────

/// Finds TVs waiting to be signed in and sends them this phone's AniList sign-in.
class PhonePairScreen extends StatefulWidget {
  const PhonePairScreen({super.key});

  @override
  State<PhonePairScreen> createState() => _PhonePairScreenState();
}

class _PhonePairScreenState extends State<PhonePairScreen> {
  final found = <String, String>{}; // "host:port" → TV name
  final manual = TextEditingController();
  bool scanning = false, sending = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    manual.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      scanning = true;
      found.clear();
    });
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..broadcastEnabled = true;
      socket.listen((event) {
        final packet = socket.receive();
        if (event != RawSocketEvent.read || packet == null) return;
        try {
          final reply = jsonDecode(utf8.decode(packet.data)) as Map;
          if (mounted) {
            setState(
              () => found['${packet.address.address}:${reply['port']}'] =
                  reply['name'] as String,
            );
          }
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
    if (mounted) setState(() => scanning = false);
  }

  Future<void> _pair(String address) async {
    final token = AniList.token;
    if (token == null) return;
    setState(() => sending = true);
    try {
      final base = 'http://${address.trim()}';
      final keys = PairKeys();
      final res = await http
          .post(
            Uri.parse('$base/pair'),
            body: jsonEncode({'pub': base64.encode(keys.publicKey)}),
          )
          .timeout(const Duration(seconds: 8));
      final agreed = keys.agree(
        base64.decode((jsonDecode(res.body) as Map)['pub']),
      );
      if (!mounted) return;
      final same = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Does your TV show this code?'),
          content: Text(
            agreed.code,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w900,
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
              child: const Text('Yes, sign in'),
            ),
          ],
        ),
      );
      if (same != true) {
        if (mounted) showError(context, 'Not signed in: the codes must match');
        return;
      }
      final sent = await http
          .post(
            Uri.parse('$base/token'),
            body: jsonEncode({'data': base64.encode(seal(agreed.key, token))}),
          )
          .timeout(const Duration(seconds: 8));
      if (sent.statusCode != 200) throw HttpException('${sent.statusCode}');
      if (!mounted) return;
      showSuccess(context, 'Your TV is signed in');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Sign in a TV'),
      bottom: sending || scanning
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'On the TV, choose Sign in in AniView. Keep both on the same Wi-Fi.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        const SizedBox(height: 16),
        for (final MapEntry(key: address, value: name) in found.entries)
          ListTile(
            leading: const Icon(Icons.tv_rounded),
            title: Text(name),
            subtitle: Text(address),
            onTap: sending ? null : () => _pair(address),
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
          onSubmitted: sending ? null : _pair,
          decoration: InputDecoration(
            labelText: 'TV address',
            hintText: '192.168.1.20:40123',
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: sending ? null : () => _pair(manual.text),
            ),
          ),
        ),
      ],
    ),
  );
}
