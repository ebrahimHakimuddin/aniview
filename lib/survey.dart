import 'package:flutter/material.dart';

import 'analytics.dart';
import 'settings.dart';
import 'states.dart';
import 'survey_dialog.dart';

const subscriptionSurveyId = 'subscription_1usd_v1';
bool _surveyOpen = false;

Future<void> maybeShowSubscriptionSurvey(BuildContext context) async {
  if (Settings.subscriptionSurveyState != null) return;
  await showSubscriptionSurvey(context);
}

Future<void> showSubscriptionSurvey(BuildContext context) async {
  if (_surveyOpen ||
      !Analytics.available ||
      !Settings.analytics ||
      Settings.subscriptionSurveyState == 'answered') {
    return;
  }
  _surveyOpen = true;
  const channel = bool.fromEnvironment('ANIVIEW_BETA') ? 'beta' : 'stable';
  try {
    Analytics.event('subscription_poll_${channel}_shown', {
      'poll_id': subscriptionSurveyId,
      'channel': channel,
    });
    final answered = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SubscriptionSurveyDialog(
        onSubmit: (answer) async {
          final sent = await Analytics.event(
            'subscription_poll_${channel}_${answer.name}',
            {
              'poll_id': subscriptionSurveyId,
              'answer': answer.name,
              'channel': channel,
            },
          );
          if (sent) await Settings.setSubscriptionSurveyState('answered');
          return sent;
        },
      ),
    );
    if (answered == true) {
      if (context.mounted) {
        showSuccess(
          context,
          'Thanks for sharing your thoughts. Your feedback helps shape AniView’s future.',
        );
      }
    } else {
      await Settings.setSubscriptionSurveyState('dismissed');
    }
  } finally {
    _surveyOpen = false;
  }
}
