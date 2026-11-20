import 'package:aniview/anilist.dart' show titleOf, titlesOf;
import 'package:aniview/settings.dart';
import 'package:aniview/upscale.dart';

import 'dart:ui' show Brightness, Rect;

import 'package:aniview/subtitle_appearance.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // The prefs keys are what installs already have saved: renaming one silently resets that setting for everyone.
  test(
    'reads every setting from the key it has always been saved under',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme_selection': 'violetLight',
        'follow_system_theme': true,
        'prefer_dub': true,
        'fallback_to_sub': true,
        'group_seasons': true,
        'changelog_seen': '9.9.9',
        'window_bounds': ['1.0', '2.0', '300.0', '400.0'],
        'preferred_source': 'kickass',
        'resume': false,
        'auto_next': false,
        'skip_mode': 'auto',
        'swipe_gestures': true,
        'seek_seconds': 30,
        'skip_seconds': 60,
        'external_player': true,
        'speed': 1.5,
        'hold_gesture': 'pause',
        'video_fit': 'cover',
        'subtitle_language': 'Spanish',
        'dub_subtitles': 'off',
        'upscale': 'quality',
        'subtitle_appearance': '{"color":4294967040,"bold":true}',
        'subtitle_size': 28.0, // the size from before appearance was one value
        'search_shortcut': ['k', 'alt'],
        'title_language': 'romaji',
        'welcome': false,
        'welcome_name': 'Ann',
        'sync_anilist': false,
        'watched_percent': 70,
        'layout': 'tv',
        'perf_overlay': true,
        'hide_nsfw': true,
        'newest_first': false,
        'random_from': 'everything',
        'stream_quality': 720,
        'download_quality': 480,
        'save_to_gallery': true,
        'episode_notifications': false,
        'release_seen_at': 42,
        'desktop_download_folder': '/media/anime',
        'jellyfin_server': 'http://jf',
        'jellyfin_token': 'tok',
        'jellyfin_user': 'u1',
        'jellyfin_user_name': 'Ann',
        'jellyseerr_server': 'http://js',
        'jellyseerr_cookie': 'c=1',
        'skip_filler': true,
        'jellyfin_device': 'dev1',
        'download_folder': 'content://tree/primary:Movies',
        'analytics': false,
        'install_id': 'abc',
        'remote_keys': ['k1'],
        'tv_remotes': '{"tv1":{"name":"Living room"}}',
        'recent_searches': ['frieren'],
        'home_sections': ['-trending'],
        'episode_tip_seen': true,
        'watching_on_migrated': true,
        'party_name': 'Mika',
        'party_relays': ['wss://relay.example.com'],
      });
      await Settings.load();
      expect(Settings.themeSelection, ThemeSelection.violetLight);
      expect(Settings.followSystemTheme, isTrue);
      expect(Settings.preferDub, isTrue);
      expect(Settings.fallbackToSub, isTrue);
      expect(Settings.groupSeasons, isTrue);
      expect(Settings.changelogSeen, '9.9.9');
      expect(Settings.windowBounds, const Rect.fromLTWH(1, 2, 300, 400));
      expect(Settings.preferredSource, 'kickass');
      expect(Settings.resume, isFalse);
      expect(Settings.autoNext, isFalse);
      expect(Settings.skipMode, SkipMode.auto);
      expect(Settings.swipeGestures, isTrue);
      expect(Settings.seekSeconds, 30);
      expect(Settings.skipSeconds, 60);
      expect(Settings.externalPlayer, isTrue);
      expect(Settings.speed, 1.5);
      expect(Settings.holdGesture, 'pause');
      expect(Settings.videoFit, BoxFit.cover);
      expect(Settings.subtitleLanguage, 'Spanish');
      expect(Settings.dubSubtitles, 'off');
      expect(Settings.upscale, Upscale.quality);
      final look = Settings.subtitleAppearance;
      expect((look.size, look.color, look.bold), (28.0, 0xffffff00, true));
      expect(Settings.searchShortcut, ['k', 'alt']);
      expect(Settings.titleLanguage, TitleLanguage.romaji);
      expect(Settings.welcome, isFalse);
      expect(Settings.welcomeName, 'Ann');
      expect(Settings.syncAniList, isFalse);
      expect(Settings.watchedPercent, 70);
      expect(Settings.layout, 'tv');
      expect(Settings.perfOverlay, isBetaBuild); // only beta builds draw it
      expect(Settings.hideNsfw, isTrue);
      expect(Settings.newestFirst, isFalse);
      expect(Settings.randomFrom, 'everything');
      expect(Settings.streamQuality, 720);
      expect(Settings.downloadQuality, 480);
      expect(Settings.saveToGallery, isTrue);
      expect(Settings.episodeNotifications, isFalse);
      expect(Settings.releaseSeenAt, 42);
      expect(Settings.desktopDownloadFolder, '/media/anime');
      expect(Settings.jellyfinServer, 'http://jf');
      expect(Settings.jellyfinToken, 'tok');
      expect(Settings.jellyfinUser, 'u1');
      expect(Settings.jellyfinUserName, 'Ann');
      expect(Settings.jellyseerrServer, 'http://js');
      expect(Settings.jellyseerrCookie, 'c=1');
      expect(Settings.skipFiller, isTrue);
      expect(Settings.jellyfinDevice, 'dev1');
      expect(Settings.downloadFolder, 'content://tree/primary:Movies');
      expect(Settings.analytics, isFalse);
      expect(Settings.installId, 'abc');
      expect(Settings.remoteKeys, ['k1']);
      expect(Settings.tvRemotes['tv1']['name'], 'Living room');
      expect(Settings.recentSearches, ['frieren']);
      expect(Settings.homeSections.first, (HomeSection.trending, false));
      expect(Settings.episodeTipSeen, isTrue);
      expect(Settings.partyName, 'Mika');
      expect(Settings.partyRelays, ['wss://relay.example.com']);
    },
  );

  test('a party starts with no name and the default relays', () async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    expect(Settings.partyName, '');
    expect(Settings.partyRelays, isEmpty);
  });

  test('upscaling starts off and keeps the tier picked', () async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    expect(Settings.upscale, Upscale.off);
    Settings.upscale = Upscale.fast;
    expect(Settings.upscale, Upscale.fast);
    await Settings.load(); // read back from the saved prefs
    expect(Settings.upscale, Upscale.fast);
    SharedPreferences.setMockInitialValues({'upscale': 'ultra'});
    await Settings.load();
    expect(Settings.upscale, Upscale.off); // an unknown tier reads as off
  });

  test('a saved subtitle size of its own wins over the legacy one', () async {
    SharedPreferences.setMockInitialValues({
      'subtitle_size': 28.0,
      'subtitle_appearance': '{"size":18}',
    });
    await Settings.load();
    expect(Settings.subtitleSize, 18);
    expect(
      SubtitleAppearance.colors,
      contains(Settings.subtitleAppearance.color),
    );
  });
  test('keeps the saved home order and appends sections added later', () async {
    SharedPreferences.setMockInitialValues({
      'home_sections': ['trending', '-featured', 'gone'],
    });
    await Settings.load();
    final sections = Settings.homeSections;
    expect(sections.take(2), [
      (HomeSection.trending, true),
      (HomeSection.featured, false),
    ]);
    expect(sections.length, HomeSection.values.length);
    expect(sections, contains((HomeSection.season, true)));
    expect(sections.last, (HomeSection.sciFi, false));
    expect(sections, contains((HomeSection.topRated, false)));
    // Appended sections start off unless they're one of the defaults.
    expect(sections, contains((HomeSection.planning, false)));

    Settings.homeSections = sections.reversed.toList();
    expect(Settings.homeSections.first, (HomeSection.sciFi, false));
    expect(Settings.homeSections.last, (HomeSection.trending, true));
  });

  test(
    'names shows in the picked language, falling back to the other',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      const show = {
        'title': {
          'userPreferred': 'Sousou no Frieren',
          'romaji': 'Sousou no Frieren',
          'english': 'Frieren: Beyond Journey’s End',
        },
      };
      const noEnglish = {
        'title': {
          'userPreferred': 'Kusuriya',
          'romaji': 'Kusuriya',
          'english': null,
        },
      };
      expect(
        titleOf(show),
        'Sousou no Frieren',
      ); // automatic: the account's pick
      Settings.titleLanguage = TitleLanguage.english;
      expect(titleOf(show), 'Frieren: Beyond Journey’s End');
      expect(titleOf(noEnglish), 'Kusuriya');
      Settings.titleLanguage = TitleLanguage.romaji;
      expect(titleOf(show), 'Sousou no Frieren');
      expect(titlesOf(show), contains('Frieren: Beyond Journey’s End'));
    },
  );

  test(
    'turns Continue watching on once for saved layouts, then leaves it be',
    () async {
      SharedPreferences.setMockInitialValues({
        'home_sections': ['trending', '-watching'],
      });
      await Settings.load();
      expect(Settings.homeSections, contains((HomeSection.watching, true)));

      Settings.homeSections = [(HomeSection.watching, false)];
      await Settings.load();
      expect(Settings.homeSections, contains((HomeSection.watching, false)));
    },
  );

  testWidgets('follows the phone\'s light and dark mode when asked to', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'theme_selection': 'violetLight'});
    await Settings.load();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    expect(Settings.activeTheme, ThemeSelection.violetLight); // off: as chosen

    Settings.followSystemTheme = true;
    expect(Settings.activeTheme, ThemeSelection.violetDark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    expect(Settings.activeTheme, ThemeSelection.violetLight);

    // The original dark look has no light twin: cyan stands in.
    expect(
      ThemeSelection.custom.inBrightness(Brightness.light),
      ThemeSelection.materialLight,
    );
    expect(
      ThemeSelection.custom.inBrightness(Brightness.dark),
      ThemeSelection.custom,
    );
  });
}
