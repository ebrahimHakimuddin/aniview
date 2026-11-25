import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'analytics.dart';
import 'changelog.dart' show discordUrl;
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
      throw FeedbackRefused(
        sendProblem(response.statusCode, response.body),
        fieldProblems(response.statusCode, response.body),
      );
    }
    Analytics.event('feedback_sent', {'type': type});
  }
}

/// The hub refused a ticket: [message] for the person, and [fields] naming what was wrong with each field it objected to.
class FeedbackRefused implements Exception {
  const FeedbackRefused(this.message, [this.fields = const {}]);

  final String message;
  final Map<String, String> fields;

  @override
  String toString() => message;
}

/// The hub's objection to each field of a refused ticket (a 400), by field name; empty for any other refusal.
Map<String, String> fieldProblems(int status, String body) {
  if (status != 400) return const {};
  try {
    final fields = (jsonDecode(body) as Map)['fields'] as Map;
    return {
      for (final MapEntry(:key, :value) in fields.entries)
        if (value is List && value.isNotEmpty) '$key': '${value.first}',
    };
  } catch (_) {
    return const {};
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

/// How bad a bug is, as the hub names it and as the person would put it; none picked means they're not sure.
const _severities = {
  'low': 'Minor',
  'medium': 'Annoying',
  'high': 'Broken',
  'critical': 'Unusable',
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

  Future<void> _discord() async {
    try {
      await AndroidApp.open(discordUrl);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isTv,
        title: const Text('Feedback'),
      ),
      body: _Centered(
        children: [
          Text('Help shape $appName', style: text.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Bug reports and ideas go straight to the developer, and every one is read.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          _Choice(
            icon: Icons.bug_report_rounded,
            title: 'Report a bug',
            body: 'Something broke or won\'t play',
            autofocus: isTv,
            onTap: () => _write('bug'),
          ),
          const SizedBox(height: 12),
          _Choice(
            icon: Icons.lightbulb_rounded,
            title: 'Request a feature',
            body: 'An idea to make $appName better',
            onTap: () => _write('feature'),
          ),
          if (!isTv) ...[
            const SizedBox(height: 24),
            Center(
              child: TextButton.icon(
                onPressed: _discord,
                icon: const Icon(Icons.forum_rounded),
                label: const Text('Rather talk it through? Join the Discord'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A page's content in one column, no wider than a form reads well, with the page's margins.
class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          side,
          16,
          side,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: children,
      ),
    ),
  );
}

/// One kind of feedback to send: a card with its icon on the accent's tint, what it's for, and where it leads.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String title, body;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Panel(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: InkWell(
        autofocus: autofocus,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(radiusLarge),
                ),
                child: Icon(icon, color: scheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
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
  String? _severity;
  var _sending = false;

  /// The hub's objection to each field, by the hub's field name, from the last refused send.
  var _problems = const <String, String>{};

  bool get _bug => widget.type == 'bug';
  String get _moreField => _bug ? 'steps' : 'problem';

  bool get _ready =>
      _title.text.trim().isNotEmpty && _description.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _description]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _more, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _problems = const {};
    });
    try {
      await SupportHub.send(
        type: widget.type,
        title: _title.text.trim(),
        description: _description.text.trim(),
        fields: {
          _moreField: _more.text,
          'severity': _severity ?? '',
          'reporterEmail': _email.text,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      final fields = e is FeedbackRefused ? e.fields : const <String, String>{};
      final shown = {'title', 'description', _moreField, 'reporterEmail'};
      setState(() {
        _sending = false;
        _problems = fields;
      });
      // A problem shown under its field needs no snackbar too.
      if (!fields.keys.any(shown.contains)) showError(context, e);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required String name,
    String? hint,
    String? helper,
    int lines = 1,
    TextInputType? keyboard,
    IconData? icon,
    bool autofocus = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
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
        helperText: helper,
        errorText: _problems[name],
        prefixIcon: icon == null ? null : Icon(icon),
        alignLabelWithHint: lines > 1,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final quiet = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isTv,
        title: Text(_bug ? 'Report a bug' : 'Request a feature'),
      ),
      body: _Centered(
        children: [
          Text(
            _bug
                ? 'Tell me what went wrong, and I\'ll look into it.'
                : 'What would make $appName better for you?',
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          _field(
            _title,
            'Title',
            name: 'title',
            hint: _bug
                ? 'Episode 3 won\'t play on Anikoto'
                : 'Download a whole season at once',
            autofocus: !isTv,
          ),
          _field(
            _description,
            _bug ? 'What happened' : 'Describe the idea',
            name: 'description',
            hint: _bug
                ? 'What you expected, and what you saw instead'
                : 'How it would work',
            lines: 4,
          ),
          _field(
            _more,
            _bug
                ? 'Steps to make it happen (optional)'
                : 'What it would help with (optional)',
            name: _moreField,
            lines: 3,
          ),
          if (_bug) ...[
            Text('How bad is it?', style: text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(:key, :value) in _severities.entries)
                  ChoiceChip(
                    label: Text(value),
                    selected: _severity == key,
                    onSelected: _sending
                        ? null
                        : (on) => setState(() => _severity = on ? key : null),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          _field(
            _email,
            'Email (optional)',
            name: 'reporterEmail',
            helper: 'Only if you\'d like a reply',
            keyboard: TextInputType.emailAddress,
            icon: Icons.alternate_email_rounded,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: buttonHeight,
            child: FilledButton.icon(
              onPressed: _sending || !_ready ? null : _send,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Sending' : 'Send'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your $appName version and device model are sent along.',
                  style: quiet,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
