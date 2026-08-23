import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'sources.dart';

/// Runs [task]; if a site answers with a Cloudflare challenge, opens a verification page for the user
/// to clear (Turnstile included), stores the resulting cookie + User-Agent, and retries.
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

class _ChallengePage extends StatefulWidget {
  const _ChallengePage(this.uri);
  final Uri uri;

  @override
  State<_ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<_ChallengePage> {
  bool _done = false;

  Future<void> _check(InAppWebViewController controller) async {
    if (_done) return;
    final title = await controller.getTitle() ?? '';
    if (title.contains('Just a moment')) return;
    final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.uri.origin));
    if (_done || !cookies.any((c) => c.name == 'cf_clearance')) return;
    _done = true;
    // Cloudflare binds the clearance cookie to the browser's User-Agent, so requests must reuse both.
    final agent = await controller.evaluateJavascript(source: 'navigator.userAgent');
    cfHeaders[widget.uri.host] = {
      'User-Agent': '$agent',
      'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
    };
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('Verifying ${widget.uri.host}'),
          bottom: const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)),
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.uri.origin)),
          onLoadStop: (controller, _) => _check(controller),
          onTitleChanged: (controller, _) => _check(controller),
        ),
      );
}
