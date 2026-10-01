import 'package:flutter/material.dart';

import 'states.dart';
import 'ui.dart';

const changelogVersion = '2.2.1';

const changelogHighlights = [
  'Updates now download inside the app, with their progress showing.',
  'Android’s install prompt appears as soon as the download finishes, with no notification to find.',
  'Updating works on TV too: the offer appears as a dialog you can reach with the remote.',
  'From Android 12, later updates install without asking again.',
];

Future<void> showChangelog(BuildContext context) => showSheet<void>(
  context,
  (sheet) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sheetTitle(sheet, 'What’s new in $changelogVersion'),
          for (final highlight in changelogHighlights)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(highlight)),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  ),
);
