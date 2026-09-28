import 'package:flutter/material.dart';

import 'states.dart';
import 'ui.dart';

const changelogVersion = '2.2.0';

const changelogHighlights = [
  'Choose from new light and dark cyan, violet, and forest themes.',
  'See recent episode releases and switch the schedule between your shows and all shows.',
  'Choose where new offline episodes are saved.',
  'Clearer progress, easier My List actions, and improved TV pairing.',
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
