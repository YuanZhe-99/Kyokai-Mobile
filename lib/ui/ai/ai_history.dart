// The host's AI tasks seen from this phone: a host sends only its latest,
// so each one shown while a link was open is kept (Sessions.aiHistory, also
// across restarts) and listed here, newest first.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../l10n/gen/app_localizations.dart';
import '../shell/app.dart';

/// Shows a host's past tasks in a sheet.
Future<void> showAiHistory(BuildContext context, String deviceId) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.95,
    builder: (context, scroll) => AiHistoryList(deviceId: deviceId, controller: scroll),
  ),
);

class AiHistoryList extends StatelessWidget {
  const AiHistoryList({super.key, required this.deviceId, this.controller});
  final String deviceId;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final sessions = AppScope.of(context).sessions;
    return ListenableBuilder(
      listenable: sessions,
      builder: (context, _) {
        final tasks = sessions.aiHistory(deviceId);
        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
              child: Row(
                children: [
                  Expanded(child: Text(l.aiHistory, style: Theme.of(context).textTheme.titleMedium)),
                  if (tasks.isNotEmpty)
                    IconButton(
                      tooltip: l.clipHistoryClear,
                      onPressed: () => sessions.clearAiHistory(deviceId),
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                ],
              ),
            ),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l.aiHistoryEmpty, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            for (final t in tasks)
              ExpansionTile(
                key: ValueKey('aiTask${t['id']}'),
                title: Text('${t['name'] ?? t['instruction'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  aiStateText(l, '${t['state'] ?? ''}'),
                  if (t['updated'] is num) _when(context, (t['updated'] as num).toInt()),
                ].join(' · ')),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (t['name'] != null) SelectableText('${t['instruction'] ?? ''}', style: TextStyle(color: cs.onSurfaceVariant)),
                  if ((t['text'] as String?)?.isNotEmpty ?? false)
                    Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText('${t['text']}')),
                  if (t['error'] != null)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('${t['error']}', style: TextStyle(color: cs.error))),
                  for (final p in (t['progress'] as List?) ?? const [])
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('· $p', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant))),
                  if (t['tokens'] is Map)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l.aiTokens(((t['tokens'] as Map)['input'] as num?)?.toInt() ?? 0, ((t['tokens'] as Map)['output'] as num?)?.toInt() ?? 0),
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  static String _when(BuildContext context, int unix) {
    final t = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    final loc = MaterialLocalizations.of(context);
    return '${loc.formatShortDate(t)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
  }
}

/// A task state's name.
String aiStateText(AppLocalizations l, String state) => switch (state) {
  'running' => l.aiRunning,
  'approval' => l.aiWaitingApproval,
  'paused' => l.aiPaused,
  'done' => l.aiDone,
  'failed' => l.aiFailed,
  'cancelled' => l.aiCancelled,
  _ => state,
};
