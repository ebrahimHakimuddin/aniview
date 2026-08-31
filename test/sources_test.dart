import 'dart:typed_data';

import 'package:aniview/downloads.dart';
import 'package:aniview/hls_proxy.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the top anime sites from everythingmoe markup', () {
    const html =
        '<div id="sec-anime" class="section"><div class="section-notes">x</div>'
        '<div data-rank="1" data-filter="Scraper" class="section-item">1. <a href="/s/anikoto" '
        'data-link="https://anikototv.to/home"><img src="a.png" alt=""> Anikoto</a></div>'
        '<div data-rank="2" data-filter="Hard-sub" class="section-item">2. <a href="/s/animepahe" '
        'data-link="https://animepahe.pw"><img src="b.png" alt=""> animepahe</a></div>'
        '<div data-rank="3" class="section-item">3. <a href="/s/reanime" data-link="https://reanime.to/home">'
        '<img src="c.png" alt=""> Re:Anime</a></div>'
        '<div data-rank="4" class="section-item">4. <a href="/s/x" data-link="https://x.to"> X</a></div></div>'
        '<div id="sec-donghua"><div data-rank="1" class="section-item">1. <a href="/s/d" data-link="https://d.to"> D</a>';
    expect(parseTopSites(html), [
      ('Anikoto', 'https://anikototv.to'),
      ('animepahe', 'https://animepahe.pw'),
      ('Re:Anime', 'https://reanime.to'),
    ]);
  });

  test('unpacks p.a.c.k.e.r scripts', () {
    const packed =
        r"eval(function(p,a,c,k,e,d){}('0 1=\'2://3.4/5.6\'',62,7,"
        r"'const|source|https|cdn|example|video|m3u8'.split('|'),0,{}))";
    expect(unpack(packed), "const source='https://cdn.example/video.m3u8'");
  });

  test('rewrites HLS playlists through the proxy', () {
    String proxy(String url, String ext) => 'P($url).$ext';
    final base = Uri.parse('https://cdn.test/a/master.m3u8');
    expect(
      rewritePlaylist(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nindex.m3u8\n',
        base,
        proxy,
      ),
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nP(https://cdn.test/a/index.m3u8).m3u8\n',
    );
    expect(
      rewritePlaylist(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.key"\n#EXTINF:10,\nhttps://img.test/x.image?s=1\n',
        base,
        proxy,
      ),
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="P(https://cdn.test/a/k.key).ts"\n#EXTINF:10,\n'
      'P(https://img.test/x.image?s=1).ts\n',
    );
  });

  test('strips fake image headers in front of MPEG-TS segments', () {
    final ts = Uint8List(188 * 4)
      ..[0] = 0x47
      ..[188] = 0x47
      ..[376] = 0x47
      ..[564] = 0x47;
    expect(
      stripToTs(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, ...ts])),
      ts,
    );
    expect(stripToTs(Uint8List.fromList([1, 2, 3])), [1, 2, 3]);
  });

  test('picks the best variant and rewrites a media playlist to local files', () {
    const master =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000\nhigh/index.m3u8\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="i.m3u8"\n';
    expect(bestVariant(master), 'high/index.m3u8');

    final (local, files, length) = localizePlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="/k/1.key"\n#EXTINF:4.5,\nseg1.ts\n'
      '#EXTINF:5.5,\nhttps://img.test/x.image?sig=1\n#EXT-X-ENDLIST\n',
      Uri.parse('https://cdn.test/a/index.m3u8'),
    );
    expect(
      local,
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key0.bin"\n#EXTINF:4.5,\nseg00000.ts\n'
      '#EXTINF:5.5,\nseg00001.ts\n#EXT-X-ENDLIST\n',
    );
    expect(files, {
      'key0.bin': Uri.parse('https://cdn.test/k/1.key'),
      'seg00000.ts': Uri.parse('https://cdn.test/a/seg1.ts'),
      'seg00001.ts': Uri.parse('https://img.test/x.image?sig=1'),
    });
    expect(length, const Duration(seconds: 10));
  });
}
