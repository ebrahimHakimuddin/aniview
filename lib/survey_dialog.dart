import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

enum SubscriptionAnswer {
  pay('Yes, I’d be more than happy to pay.'),
  donate('Keep the app free. I’ll try to donate more often.'),
  dealbreaker('A subscription would be a dealbreaker for me.');

  const SubscriptionAnswer(this.label);
  final String label;
}

class SubscriptionSurveyDialog extends StatefulWidget {
  const SubscriptionSurveyDialog({super.key, required this.onSubmit});

  final Future<bool> Function(SubscriptionAnswer) onSubmit;

  @override
  State<SubscriptionSurveyDialog> createState() =>
      _SubscriptionSurveyDialogState();
}

class _SubscriptionSurveyDialogState extends State<SubscriptionSurveyDialog> {
  SubscriptionAnswer? _answer;
  bool _sending = false;
  String? _error;

  Future<void> _submit() async {
    if (_sending || _answer == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    var sent = false;
    try {
      sent = await widget.onSubmit(_answer!);
    } catch (_) {
      // Keep the selection so the person can retry.
    }
    if (!mounted) return;
    if (sent) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _sending = false;
        _error =
            'Couldn’t send your answer. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: 560),
      title: const Text('Would you pay US\$1 per month to use AniView?'),
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'A subscription would support development and let me dedicate more '
              'time to maintaining the embedded servers, fixing bugs, and releasing '
              'new features faster—while keeping the app polished and reliable.',
            ),
            const SizedBox(height: 16),
            RadioGroup<SubscriptionAnswer>(
              groupValue: _answer,
              onChanged: (value) {
                if (!_sending) setState(() => _answer = value);
              },
              child: Column(
                children: [
                  for (final answer in SubscriptionAnswer.values)
                    RadioListTile<SubscriptionAnswer>(
                      value: answer,
                      title: Text(answer.label),
                      contentPadding: EdgeInsets.zero,
                      enabled: !_sending,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Nothing is changing yet—your feedback will help me decide.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _sending || _answer == null ? null : _submit,
          child: _sending
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Sending answer',
                  ),
                )
              : const Text('Submit answer'),
        ),
      ],
    ),
  );
}

@Preview(name: 'Subscription survey', size: Size(390, 844))
Widget subscriptionSurveyPreview() => MaterialApp(
  theme: ThemeData(
    colorSchemeSeed: const Color(0xFF01C4FA),
    brightness: Brightness.dark,
  ),
  home: Scaffold(body: SubscriptionSurveyDialog(onSubmit: (_) async => false)),
);
