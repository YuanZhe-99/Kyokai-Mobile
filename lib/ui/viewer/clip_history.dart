// What crossed the sessions' clipboards, both ways, newest first: the host's
// copies and the phone's, text and images. Tapping one copies it again
// (then sessions offer it to their hosts as anything copied here).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/model.dart';
import '../../data/sessions.dart';
import '../shell/app.dart';

class ClipHistoryPage extends StatelessWidget {
  const ClipHistoryPage({super.key, this.deviceId});

  /// Only this host's entries; null for all.
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final sessions = AppScope.of(context).sessions;
    return ListenableBuilder(
      listenable: sessions,
      builder: (context, _) {
        final entries = sessions.clipHistory.where((e) => deviceId == null || e.deviceId == deviceId).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(l.clipHistory),
            actions: [
              if (sessions.clipHistory.isNotEmpty)
                IconButton(
                  tooltip: l.clipHistoryClear,
                  onPressed: sessions.clearClipHistory,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
            ],
          ),
          body: entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l.clipHistoryEmpty, textAlign: TextAlign.center),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 32),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _EntryTile(entry: entries[i], showHost: deviceId == null),
                ),
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.showHost});
  final ClipEntry entry;
  final bool showHost;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final state = AppScope.of(context);
    final host = state.engine.status.host(entry.deviceId)?.title ?? formatId(entry.deviceId);
    final loc = MaterialLocalizations.of(context);
    final when = loc.formatTimeOfDay(TimeOfDay.fromDateTime(entry.at));
    final from = entry.fromHost ? l.clipFromHost(host) : (showHost ? l.clipToHost(host) : l.clipFromPhone);
    final copyable = entry.text != null || entry.png != null;
    return ListTile(
      leading: Icon(entry.fromHost ? Icons.south_west : Icons.north_east, color: cs.primary),
      title: entry.png != null
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  entry.png!,
                  height: 96,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 48),
                ),
              ),
            )
          : Text(
              entry.text ?? l.clipFiles(entry.files),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: entry.text == null ? TextStyle(color: cs.onSurfaceVariant) : null,
            ),
      subtitle: Text('$from · $when'),
      trailing: copyable
          ? IconButton(
              tooltip: l.copy,
              icon: const Icon(Icons.copy),
              onPressed: () => _copy(context),
            )
          : null,
      onTap: copyable ? () => _copy(context) : null,
    );
  }

  void _copy(BuildContext context) {
    final l = context.l;
    unawaited(AppScope.of(context).sessions.copyAgain(entry));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
  }
}
