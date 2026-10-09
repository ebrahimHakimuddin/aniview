import 'package:aniview/changelog.dart';
import 'package:aniview/home.dart';
import 'package:aniview/main.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'a const artwork header follows system brightness without restarting',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'theme_selection': 'materialDark',
        'follow_system_theme': true,
      });
      await Settings.load();
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final changed = ValueNotifier(0);
      addTearDown(changed.dispose);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: changed,
          builder: (_, _, _) => MaterialApp(
            theme: buildTheme(),
            themeAnimationDuration: Duration.zero,
            home: const Scaffold(body: Stack(children: [HeaderScrim()])),
          ),
        ),
      );
      LinearGradient gradient() {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byType(HeaderScrim),
            matching: find.byType(DecoratedBox),
          ),
        );
        return (box.decoration as BoxDecoration).gradient! as LinearGradient;
      }

      expect(gradient().colors.first, scheme.surface);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      changed.value++;
      await tester.pump();
      expect(gradient().colors.take(2), [scheme.surface, scheme.surface]);
      expect(scheme.brightness, Brightness.light);
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'phone'} switches its logo with system brightness',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'changelog_seen': changelogVersion,
          'theme_selection': 'materialDark',
          'follow_system_theme': true,
        });
        await Settings.load();
        isDesktop = desktop;
        addTearDown(() => isDesktop = false);
        tester.view.physicalSize = desktop
            ? const Size(1600, 1000)
            : const Size(500, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(const App());
        await tester.pump(const Duration(milliseconds: 400));
        Finder logo(String name) => find.byWidgetPredicate((widget) {
          if (widget is! Image) return false;
          final provider = widget.image is ResizeImage
              ? (widget.image as ResizeImage).imageProvider
              : widget.image;
          return provider is AssetImage &&
              provider.assetName == 'assets/icon/$name.png';
        });
        expect(logo('aniview_wordmark'), findsOneWidget);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pump();
        await tester.pump();
        expect(logo('aniview_wordmark_light'), findsOneWidget);
        expect(logo('aniview_wordmark'), findsNothing);
      },
    );
  }

  testWidgets('light hero labels stay clear over artwork', (tester) async {
    // Home shows the what's-new dialog on a version's first launch; these tests start past it.
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
    });
    await Settings.load();
    addTearDown(() => Settings.themeSelection = ThemeSelection.custom);

    for (final choice in [
      ThemeSelection.materialLight,
      ThemeSelection.violetLight,
      ThemeSelection.forestLight,
    ]) {
      Settings.themeSelection = choice;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: Eyebrow('Trending')),
        ),
      );

      final label = tester.widget<Text>(find.text('TRENDING'));
      expect(label.style?.shadows, isNull);
      final fade = keyArtFade.gradient! as LinearGradient;
      final background = Color.alphaBlend(fade.colors[3], Colors.black);
      final foreground = label.style!.color!;
      final brighter = [
        foreground.computeLuminance(),
        background.computeLuminance(),
      ]..sort();
      final contrast = (brighter.last + .05) / (brighter.first + .05);
      expect(contrast, greaterThanOrEqualTo(4.5), reason: choice.name);
    }
  });

  testWidgets('theme colors change together without a mixed-color frame', (
    tester,
  ) async {
    // Home shows the what's-new dialog on a version's first launch; these tests start past it.
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
    });
    await Settings.load();
    await tester.pumpWidget(const App());

    Settings.themeSelection = ThemeSelection.violetLight;
    themeGeneration.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final page = tester.element(find.byType(HomeScreen));
    expect(Theme.of(page).colorScheme.primary, scheme.primary);
    Settings.themeSelection = ThemeSelection.custom;
  });
}
