// What crossed the sessions' clipboards, both ways, newest first: the host's
// copies and the phone's, text, images and files. Tapping text or an image
// copies it again (then sessions offer it to their hosts as anything copied
// here); the host's files, kept for this run of the app, are saved or shared.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/model.dart';
import '../../data/sessions.dart';
import '../shell/app.dart';
import '../shell/save_share.dart';

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
    final kept = entry.kept.isNotEmpty;
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
              entry.text ?? (kept ? entry.kept.map(_name).join(', ') : l.clipFiles(entry.files)),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: entry.text == null ? TextStyle(color: cs.onSurfaceVariant) : null,
            ),
      subtitle: Text(kept ? '${l.clipFiles(entry.files)} · $from · $when' : '$from · $when'),
      trailing: copyable
          ? IconButton(
              tooltip: l.copy,
              icon: const Icon(Icons.copy),
              onPressed: () => _copy(context),
            )
          : kept
          ? IconButton(
              tooltip: l.filesShare,
              icon: const Icon(Icons.share),
              onPressed: () => _share(context, entry.kept),
            )
          : null,
      onTap: copyable ? () => _copy(context) : (kept ? () => _files(context) : null),
    );
  }

  static String _name(String path) => path.split('/').last;

  /// Every file of the copied items, folders gone through.
  static Future<List<String>> _allFiles(List<String> paths) async => [
    for (final p in paths)
      if (await FileSystemEntity.isDirectory(p))
        ...(await Directory(p).list(recursive: true).where((e) => e is File).map((e) => e.path).toList())
      else
        p,
  ];

  Future<void> _share(BuildContext context, List<String> paths) async {
    final l = context.l;
    final messenger = ScaffoldMessenger.of(context);
    final files = await _allFiles(paths);
    if (files.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l.clipFilesGone)));
      return;
    }
    await shareFiles(files);
  }

  Future<void> _save(BuildContext context, String path) async {
    final l = context.l;
    final messenger = ScaffoldMessenger.of(context);
    final f = File(path);
    if (!await f.exists()) {
      messenger.showSnackBar(SnackBar(content: Text(l.clipFilesGone)));
    } else if (await f.length() > saveLimit) {
      messenger.showSnackBar(SnackBar(content: Text(l.filesTooBigToSave)));
    } else if (await saveFileAs(path, _name(path))) {
      messenger.showSnackBar(SnackBar(content: Text(l.filesSaved)));
    }
  }

  /// The copied items, each to save (a file) or share.
  Future<void> _files(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final l = sheet.l;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in entry.kept)
              ListTile(
                leading: Icon(FileSystemEntity.isDirectorySync(p) ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                title: Text(_name(p)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!FileSystemEntity.isDirectorySync(p))
                      IconButton(tooltip: l.save, icon: const Icon(Icons.save_alt), onPressed: () => _save(context, p)),
                    IconButton(tooltip: l.filesShare, icon: const Icon(Icons.share), onPressed: () => _share(context, [p])),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  void _copy(BuildContext context) {
    final l = context.l;
    unawaited(AppScope.of(context).sessions.copyAgain(entry));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
  }
}
