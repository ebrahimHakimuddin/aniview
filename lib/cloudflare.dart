import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'net.dart';

/// How a person is asked to pass a site's Cloudflare check: true once it's passed. The caller decides what that means
/// (a verification page, nothing at all in the background), so what runs the task needn't have a screen to show it on.
typedef ChallengeHandler = Future<bool> Function(CloudflareChallenge challenge);

/// Runs [task]; when a site needs a check the person has to complete (e.g. Turnstile), [onChallenge] gets it passed and
/// the task is retried. Without a handler, or when it can't be passed, the challenge is thrown.
Future<T> withChallenge<T>(
  ChallengeHandler? onChallenge,
  Future<T> Function() task,
) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await task();
    } on CloudflareChallenge catch (challenge) {
      if (attempt == 3 || onChallenge == null) rethrow;
      if (!await onChallenge(challenge)) rethrow;
    }
  }
}

/// Shows the check in a full-screen verification page over [context]'s screen.
ChallengeHandler uiChallenge(BuildContext context) => (challenge) async {
  if (!context.mounted) return false;
  final solved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ChallengePage(Uri.parse(challenge.url)),
    ),
  );
  return solved == true;
};

/// [withChallenge], with the verification page on [context]'s screen.
Future<T> withCloudflare<T>(BuildContext context, Future<T> Function() task) =>
    withChallenge(uiChallenge(context), task);

/// Loads [url] in an invisible WebView — Chromium's network stack plus the shared cookie jar, which Cloudflare
/// accepts — and returns the page HTML, or its text for JSON endpoints. Automatic Cloudflare checks are given
/// a few seconds to pass; ones that need the user throw [CloudflareChallenge] for [withCloudflare] to show.
Future<String> browserFetch(
  String url, {
  String? referer,
  bool text = false,
}) async {
  final result = Completer<String>();
  Timer? challengeTimeout;
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(
      url: WebUri(url),
      headers: {'Referer': ?referer},
    ),
    onLoadStop: (controller, _) async {
      if (result.isCompleted) return;
      if (_isChallenge(await controller.getTitle() ?? '')) {
        challengeTimeout ??= Timer(const Duration(seconds: 8), () {
          if (!result.isCompleted) {
            result.completeError(CloudflareChallenge(url));
          }
        });
        return;
      }
      final body = await controller.evaluateJavascript(
        source: text
            ? 'document.body.innerText'
            : 'document.documentElement.outerHTML',
      );
      if (!result.isCompleted) result.complete('${body ?? ''}');
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !result.isCompleted) {
        result.completeError(
          HttpException(error.description, uri: Uri.parse(url)),
        );
      }
    },
  );
  await view.run();
  try {
    return await result.future.timeout(const Duration(seconds: 40));
  } finally {
    challengeTimeout?.cancel();
    await view.dispose();
  }
}

/// GETs over HTTP/2 with the in-app browser's cookies and user agent (what a cf_clearance cookie is bound to), so
/// only the first request to a Cloudflare-challenged site pays for a WebView. Without a valid clearance, the site is
/// opened in the browser first ([browserFetch]), which may throw [CloudflareChallenge].
class CloudflareNet implements Net {
  /// [request] and [verify] are what touch the WebView and its cookies; replaced in tests.
  CloudflareNet({
    Future<(int, Uint8List)> Function(Uri uri, Map<String, String> headers)?
    request,
    Future<void> Function(String origin)? verify,
  }) : _request = request ?? _withCookies,
       _verify = verify ?? ((origin) => browserFetch(origin));

  final Future<(int, Uint8List)> Function(Uri, Map<String, String>) _request;
  final Future<void> Function(String) _verify;

  static Future<(int, Uint8List)> _withCookies(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri('$uri'),
    );
    final (status, _, body) = await h2Get(uri, {
      ...headers,
      'user-agent': await _browserAgent,
      'cookie': [for (final c in cookies) '${c.name}=${c.value}'].join('; '),
    });
    return (status, body);
  }

  @override
  Future<Uint8List> bytes(String url, {Map<String, String>? headers}) async {
    final uri = Uri.parse(url);
    var (status, body) = await _request(uri, headers ?? const {});
    if (status == 403 || status == 503) {
      await _verify('${uri.origin}/');
      (status, body) = await _request(uri, headers ?? const {});
    }
    if (status != 200) throw HttpException('HTTP $status', uri: uri);
    return body;
  }

  @override
  Future<String> text(String url, {Map<String, String>? headers}) async =>
      utf8.decode(await bytes(url, headers: headers), allowMalformed: true);
}

final _browserAgent = _defaultAgent();

Future<String> _defaultAgent() async {
  try {
    return await InAppWebViewController.getDefaultUserAgent();
  } catch (_) {
    return _pageAgent(); // not implemented on Linux
  }
}

/// The WebView's own user agent, read from a page, where the platform can't give it directly (Linux): a
/// cf_clearance cookie only works with the agent that earned it. A common desktop one if that fails too.
Future<String> _pageAgent() async {
  final agent = Completer<String>();
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri('about:blank')),
    onLoadStop: (controller, _) async {
      if (agent.isCompleted) return;
      final ua = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      agent.complete('$ua');
    },
  );
  try {
    await view.run();
    return await agent.future.timeout(const Duration(seconds: 5));
  } catch (_) {
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
  } finally {
    await view.dispose();
  }
}

bool _isChallenge(String title) =>
    title.contains('Just a moment') || title.contains('Attention Required');

class _ChallengePage extends StatefulWidget {
  const _ChallengePage(this.uri);
  final Uri uri;

  @override
  State<_ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<_ChallengePage> {
  bool _done = false;

  // The WebView shares its cookie jar with [browserFetch], so clearing the check here is all that's needed.
  Future<void> _check(InAppWebViewController controller) async {
    if (_done || _isChallenge(await controller.getTitle() ?? '')) return;
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(widget.uri.origin),
    );
    if (_done || !cookies.any((c) => c.name == 'cf_clearance')) return;
    _done = true;
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Verifying ${widget.uri.host}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Done'),
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(2),
        child: LinearProgressIndicator(minHeight: 2),
      ),
    ),
    body: InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.uri.toString())),
      onLoadStop: (controller, _) => _check(controller),
      onTitleChanged: (controller, _) => _check(controller),
    ),
  );
}
