// Prints everythingmoe's anime streaming ranking as `name|origin;…` for the build:
// fvm flutter build apk --dart-define=TOP_SITES="$(fvm dart run tool/top_sites.dart)"
import 'dart:convert';
import 'dart:io';

/// (name, origin) of the entries in everythingmoe's "Anime Streaming" section, in rank order.
List<(String, String)> parseTopSites(String html) {
  final start = html.indexOf('id="sec-anime"');
  if (start == -1) {
    throw const FormatException(
      'everythingmoe layout changed: no anime section',
    );
  }
  final end = html.indexOf('id="sec-', start + 1);
  final section = html.substring(start, end == -1 ? html.length : end);
  return RegExp(
        r'class="section-item">(?:<span[^>]*>)?\d+\.(?:</span>)?\s*<a href="[^"]*" data-link="([^"]+)"[^>]*>(?:<img[^>]*>)?\s*([^<]+)</a>',
      )
      .allMatches(section)
      .map((m) => (m[2]!.trim(), Uri.parse(m[1]!).origin))
      .toList();
}

Future<void> main() async {
  final client = HttpClient();
  final res = await (await client.getUrl(
    Uri.parse('https://everythingmoe.com/'),
  )).close();
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
  final sites = parseTopSites(await res.transform(utf8.decoder).join());
  if (sites.isEmpty) throw const FormatException('everythingmoe listed no sites');
  client.close();
  stdout.write(sites.map((s) => '${s.$1}|${s.$2}').join(';'));
}
