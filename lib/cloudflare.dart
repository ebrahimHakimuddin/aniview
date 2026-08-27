import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'sources.dart';

/// Runs [task]; when a site needs a Cloudflare check the user has to complete (e.g. Turnstile),
/// shows it in a verification page and retries once it's cleared.
Future<T> withCloudflare<T>(BuildContext context, Future<T> Function() task) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await task();
    } on CloudflareChallenge catch (challenge) {
      if (attempt == 3 || !context.mounted) rethrow;
      final solved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ChallengePage(Uri.parse(challenge.url)),
      ));
      if (solved != true) rethrow;
    }
  }
}

/// Loads [url] in an invisible WebView — Chromium's network stack plus the shared cookie jar, which Cloudflare
/// accepts — and returns the page HTML, or its text for JSON endpoints. Automatic Cloudflare checks are given
/// a few seconds to pass; ones that need the user throw [CloudflareChallenge] for [withCloudflare] to show.
Future<String> browserFetch(String url, {String? referer, bool text = false}) async {
  final result = Completer<String>();
  Timer? challengeTimeout;
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url), headers: {'Referer': ?referer}),
    onLoadStop: (controller, _) async {
      if (result.isCompleted) return;
      if (_isChallenge(await controller.getTitle() ?? '')) {
        challengeTimeout ??= Timer(const Duration(seconds: 8), () {
          if (!result.isCompleted) result.completeError(CloudflareChallenge(url));
        });
        return;
      }
      final body = await controller.evaluateJavascript(
        source: text ? 'document.body.innerText' : 'document.documentElement.outerHTML',
      );
      if (!result.isCompleted) result.complete('${body ?? ''}');
    },
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != false && !result.isCompleted) {
        result.completeError(HttpException(error.description, uri: Uri.parse(url)));
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

bool _isChallenge(String title) => title.contains('Just a moment') || title.contains('Attention Required');

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
    final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.uri.origin));
    if (_done || !cookies.any((c) => c.name == 'cf_clearance')) return;
    _done = true;
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('Verifying ${widget.uri.host}'),
          actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))],
          bottom: const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)),
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.uri.toString())),
          onLoadStop: (controller, _) => _check(controller),
          onTitleChanged: (controller, _) => _check(controller),
        ),
      );
}
