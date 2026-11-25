import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'analytics.dart';
import 'platform.dart';
import 'settings.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

/// Bug reports and feature requests, sent to the support hub's ticket API. The key is built into the app and can only
/// send.
class SupportHub {
  static const _key = String.fromEnvironment('SUPPORT_HUB_KEY');
  static const _host = String.fromEnvironment(
    'SUPPORT_HUB_URL',
    defaultValue: 'https://hub.ebrahim.co.tz',
  );

  static bool get available => _key.isNotEmpty;

  static Map<String, String> get _auth => {'Authorization': 'Bearer $_key'};

  /// Sends a ticket; [fields] are the hub's optional fields (`steps`, `severity`, `problem`, `reporterEmail`…).
  static Future<void> send({
    required String type,
    required String title,
    required String description,
    Map<String, String> fields = const {},
  }) async {
    final version = await AndroidApp.version() ?? '';
    final device = await AndroidApp.device() ?? '';
    final form = {
      'type': type,
      'title': title,
      'description': description,
      for (final MapEntry(:key, :value) in fields.entries)
        if (value.trim().isNotEmpty) key: value.trim(),
      'appVersion': version,
      'userAgent': [
        '$appName $version',
        '${Platform.operatingSystem}${isTv ? ' TV' : ''}',
        device,
      ].join('; '),
    };
    final request =
        http.MultipartRequest('POST', Uri.parse('$_host/api/v1/tickets'))
          ..headers.addAll(_auth)
          ..fields.addAll(form);
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(seconds: 30)),
    );
    if (response.statusCode != 201) {
      throw Exception(sendProblem(response.statusCode, response.body));
    }
    Analytics.event('feedback_sent', {'type': type});
  }
}

/// What to tell the person when the hub refused a ticket.
String sendProblem(int status, String body) {
  if (status == 400) {
    try {
      final fields = (jsonDecode(body) as Map)['fields'] as Map;
      final first = fields.values.whereType<List>().expand((m) => m).first;
      return '$first';
    } catch (_) {}
  }
  return switch (status) {
    401 => 'Feedback isn\'t set up in this version of $appName',
    413 => 'That report is too long. Shorten it and try again',
    429 => 'Too many reports right now. Try again in a minute',
    _ => 'The support hub returned an error ($status)',
  };
}

const _severities = {
  '': 'Not sure',
  'low': 'Minor: a small annoyance',
  'medium': 'Gets in the way',
  'high': 'Stops something from working',
  'critical': 'The app is unusable',
};

/// Settings → About → Feedback: send a bug report or a feature request.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  @override
  void initState() {
    super.initState();
    Analytics.screen('/settings/feedback', title: 'Feedback');
  }

  Future<void> _write(String type) async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _TicketForm(type)),
    );
    if (sent != true || !mounted) return;
    showSuccess(
      context,
      type == 'bug' ? 'Thanks, the bug is reported' : 'Thanks, idea sent',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isTv,
        title: const Text('Feedback'),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: 32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          ListTile(
            autofocus: isTv,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Report a bug'),
            subtitle: const Text('Something broke or doesn\'t work right'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _write('bug'),
          ),
          ListTile(
            leading: const Icon(Icons.lightbulb_outline_rounded),
            title: const Text('Request a feature'),
            subtitle: const Text('An idea that would make AniView better'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _write('feature'),
          ),
        ],
      ),
    );
  }
}

class _TicketForm extends StatefulWidget {
  const _TicketForm(this.type);

  final String type;

  @override
  State<_TicketForm> createState() => _TicketFormState();
}

class _TicketFormState extends State<_TicketForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _more = TextEditingController();
  final _email = TextEditingController();
  var _severity = '';
  var _sending = false;

  bool get _bug => widget.type == 'bug';

  @override
  void dispose() {
    for (final c in [_title, _description, _more, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    if (_title.text.trim().isEmpty || _description.text.trim().isEmpty) {
      showError(
        context,
        _bug
            ? 'Give the bug a title and say what happened'
            : 'Give the idea a title and describe it',
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await SupportHub.send(
        type: widget.type,
        title: _title.text.trim(),
        description: _description.text.trim(),
        fields: {
          _bug ? 'steps' : 'problem': _more.text,
          'severity': _severity,
          'reporterEmail': _email.text,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showError(context, e);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    int lines = 1,
    TextInputType? keyboard,
    bool autofocus = false,
  }) => Padding(
    padding: EdgeInsets.symmetric(horizontal: side, vertical: 8),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: !_sending,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 8,
      keyboardType: keyboard,
      textCapitalization: keyboard == null
          ? TextCapitalization.sentences
          : TextCapitalization.none,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: lines > 1,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: !isTv,
      title: Text(_bug ? 'Report a bug' : 'Request a feature'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: EdgeInsets.only(
            top: 8,
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _field(
              _title,
              'Title',
              hint: _bug ? 'Episode 3 won\'t play on Anikoto' : null,
              autofocus: !isTv,
            ),
            _field(
              _description,
              _bug ? 'What happened' : 'What would you like',
              lines: 4,
            ),
            _field(
              _more,
              _bug
                  ? 'Steps to make it happen (optional)'
                  : 'What it would help with (optional)',
              lines: 3,
            ),
            if (_bug)
              ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: side),
                title: const Text('How bad is it'),
                subtitle: Text(_severities[_severity]!),
                enabled: !_sending,
                onTap: () async {
                  final picked = await pickOne(
                    context,
                    'How bad is it',
                    _severities,
                    _severity,
                  );
                  if (picked != null) setState(() => _severity = picked);
                },
              ),
            _field(
              _email,
              'Email, if you\'d like a reply (optional)',
              keyboard: TextInputType.emailAddress,
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(side, 4, side, 0),
              child: Text(
                'Your $appName version and device model are sent with it.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 0),
              child: FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
