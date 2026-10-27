import 'dart:async';
import 'dart:convert';

import 'package:aniview/analytics.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/survey.dart';
import 'package:aniview/survey_dialog.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'AniView',
      packageName: 'com.kidfury.aniview',
      version: 'test',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
  });

  Future<void> open(
    WidgetTester tester,
    Future<bool> Function(SubscriptionAnswer) submit,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => SubscriptionSurveyDialog(onSubmit: submit),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tryDismiss(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(find.byType(SubscriptionSurveyDialog), findsOneWidget);
  }

  testWidgets(
    'requires selection, prevents double submit, and closes on success',
    (tester) async {
      final pending = Completer<bool>();
      final answers = <SubscriptionAnswer>[];
      await open(tester, (answer) {
        answers.add(answer);
        return pending.future;
      });
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(find.text('Not now'), findsNothing);
      await tryDismiss(tester);
      await tester.tap(find.text(SubscriptionAnswer.pay.label));
      await tester.pump();
      await tester.tap(find.text('Submit answer'));
      await tester.pump();
      expect(answers, [SubscriptionAnswer.pay]);
      await tryDismiss(tester);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionSurveyDialog), findsNothing);
    },
  );

  testWidgets('failed delivery keeps the answer selected and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    await open(tester, (_) async => ++attempts > 1);
    await tester.tap(find.text(SubscriptionAnswer.dealbreaker.label));
    await tester.pump();
    await tester.tap(find.text('Submit answer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn’t send'), findsOneWidget);
    expect(find.byType(SubscriptionSurveyDialog), findsOneWidget);
    await tryDismiss(tester);
    await tester.tap(find.text('Submit answer'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(SubscriptionSurveyDialog), findsNothing);
  });

  testWidgets(
    'small screen and enlarged text remain usable without allowing dismissal',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, (_) async => throw StateError('should not submit'));
      expect(tester.takeException(), isNull);
      expect(find.text('Not now'), findsNothing);
      await tryDismiss(tester);
    },
  );

  testWidgets('legacy dismissal prompts again until an answer is submitted', (
    tester,
  ) async {
    await Settings.setSubscriptionSurveyState('dismissed');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => maybeShowSubscriptionSurvey(context),
              child: const Text('Launch'),
            ),
          ),
        ),
      ),
    );
    await http.runWithClient(() async {
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('Not now'), findsNothing);
      expect(find.byType(SubscriptionSurveyDialog), findsOneWidget);
      await tryDismiss(tester);
      expect(Settings.subscriptionSurveyState, 'dismissed');
      await tester.tap(find.text(SubscriptionAnswer.donate.label));
      await tester.pump();
      await tester.tap(find.text('Submit answer'));
      await tester.pumpAndSettle();
      expect(Settings.subscriptionSurveyState, 'answered');
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionSurveyDialog), findsNothing);
    }, () => MockClient((_) async => http.Response('{"success":true}', 200)));
  }, skip: !Analytics.available);

  for (final answer in SubscriptionAnswer.values) {
    testWidgets('submission sends the channel-specific ${answer.name} event', (
      tester,
    ) async {
      const channel = isBetaBuild ? 'beta' : 'stable';
      final requests = <http.Request>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSubscriptionSurvey(context),
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );
      await http.runWithClient(
        () async {
          await tester.tap(find.text('Launch'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(answer.label));
          await tester.pump();
          await tester.tap(find.text('Submit answer'));
          await tester.pumpAndSettle();
          expect(Settings.subscriptionSurveyState, 'answered');
          final events = requests
              .map(
                (request) => jsonDecode(request.body) as Map<String, dynamic>,
              )
              .toList();
          expect(events.map((event) => event['event_name']), [
            'subscription_poll_${channel}_shown',
            'subscription_poll_${channel}_${answer.name}',
          ]);
          expect(jsonDecode(events.last['properties'] as String), {
            'poll_id': subscriptionSurveyId,
            'answer': answer.name,
            'channel': channel,
          });
          await tester.tap(find.text('Launch'));
          await tester.pumpAndSettle();
          expect(requests, hasLength(2));
        },
        () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"success":true}', 200);
        }),
      );
    }, skip: !Analytics.available);
  }

  testWidgets(
    'delivery requires a successful HTTP response and Rybbit acknowledgement',
    (tester) async {
      for (final (status, body, expected) in [
        (404, '{"success":false}', false),
        (200, '{"success":false}', false),
        (200, 'not json', false),
        (200, '{"success":true}', true),
      ]) {
        final requests = <http.Request>[];
        final pending = http.runWithClient(
          () =>
              Analytics.event('subscription_poll_answered', {'answer': 'pay'}),
          () => MockClient((request) async {
            requests.add(request);
            return http.Response(body, status);
          }),
        );
        await tester.pumpAndSettle();
        expect(await pending, expected);
        expect(requests, hasLength(1));
        expect(requests.single.url.host, 'rybbit.clouderp.co.tz');
        expect(
          jsonDecode(requests.single.body)['event_name'],
          'subscription_poll_answered',
        );
      }
      Settings.analytics = false;
      final pending = http.runWithClient(
        () => Analytics.event('subscription_poll_answered'),
        () => MockClient((_) async => throw StateError('must not send')),
      );
      await tester.pumpAndSettle();
      expect(await pending, false);
    },
    skip: !Analytics.available,
  );
}
