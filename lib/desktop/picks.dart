import 'package:flutter/material.dart';

import '../selection.dart';
import '../states.dart';
import '../tracker.dart';
import '../ui.dart';
import '../anilist.dart';

/// Shows picked with a poster's checkbox anywhere but My list (which keeps its own): Home's rows, Search. One set for
/// the whole desktop, acted on from [DeskPickBar]; the shell clears it when you change place.
final deskPicks = Selection<Object?, Map>((media) => media['id']);

/// The bar over the page's foot while shows are picked: put them all on a list, or let go.
class DeskPickBar extends StatelessWidget {
  const DeskPickBar({super.key, required this.onChanged});

  /// Called when picked shows were saved to the list, so the page can show it.
  final VoidCallback onChanged;

  Future<void> _addTo(BuildContext context, String status) async {
    final result = await deskPicks.runBulk(
      (m) => Tracker.save(m, Show(m).progress, status: status),
    );
    if (!context.mounted) return;
    final message = bulkMessage(
      result,
      'Added ${result.total} to ${ListStatus.labels[status]}',
    );
    result.ok ? showSuccess(context, message) : showError(context, message);
    onChanged();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: deskPicks,
    builder: (context, _) {
      if (!deskPicks.active && !deskPicks.busy) return const SizedBox.shrink();
      return SelectionBar(
        count: deskPicks.count,
        onDone: deskPicks.clear,
        busy: deskPicks.busy,
        actions: [
          PopupMenuButton<String>(
            enabled: !deskPicks.busy,
            tooltip: 'Add to list',
            onSelected: (status) => _addTo(context, status),
            itemBuilder: (_) => [
              for (final MapEntry(:key, :value) in ListStatus.movable.entries)
                PopupMenuItem(value: key, child: Text(value)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.bookmark_add_outlined, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Add to list',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: scheme.primary),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
