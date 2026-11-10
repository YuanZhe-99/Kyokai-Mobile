// A device's files over SFTP: one folder at a time with a path bar, what
// to do with a file or folder, uploads from the phone, downloads into the
// app's storage offered to share or save, and the transfers' progress.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/clients.dart';
import '../../data/services.dart';
import '../../l10n/gen/app_localizations.dart';
import '../shell/app.dart';
import '../shell/save_share.dart';
import 'service_open.dart';

/// A file the phone picked: where its copy is, and its name.
typedef PickedFile = ({String path, String name});

class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.session,
    this.pickFiles = _pickFiles,
    this.saveFile = saveFileAs,
    this.shareFile = _shareFile,
    this.downloads = _downloads,
  });

  final FilesSession session;

  /// The phone's files to upload; empty when none were chosen.
  final Future<List<PickedFile>> Function() pickFiles;

  /// Saves a downloaded file where the person chooses; false when not.
  final Future<bool> Function(String path, String name) saveFile;

  /// Offers a downloaded file to other apps.
  final Future<void> Function(String path) shareFile;

  /// The folder downloads go into.
  final Future<String> Function() downloads;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

Future<List<PickedFile>> _pickFiles() async {
  final r = await FilePicker.platform.pickFiles(allowMultiple: true);
  return [
    for (final f in r?.files ?? const <PlatformFile>[])
      if (f.path != null) (path: f.path!, name: f.name),
  ];
}

Future<void> _shareFile(String path) => shareFiles([path]);

Future<String> _downloads() async => '${(await getTemporaryDirectory()).path}/downloads';

/// What a files call's failure means.
String filesErrorText(AppLocalizations l, Object e) => switch (e is ClientsError ? e.message : '$e') {
  'permission-denied' => l.filesErrPermission,
  'not-found' => l.filesErrNotFound,
  'exists' => l.filesErrExists,
  'is-folder' => l.filesErrIsFolder,
  'connection-lost' || 'not connected' || 'no such client' => l.filesErrConnectionLost,
  final other => l.filesErrOther(other),
};

/// A size as people read it: 1.2 MB.
String fileSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

class _FilesPageState extends State<FilesPage> {
  FilesSession get s => widget.session;

  /// Downloads already announced as done.
  final _announced = <FileTransfer>{};

  @override
  void initState() {
    super.initState();
    s.addListener(_changed);
  }

  @override
  void dispose() {
    s.removeListener(_changed);
    super.dispose();
  }

  /// Offers each download once it is done.
  void _changed() {
    if (!mounted) return;
    for (final t in s.transfers) {
      if (t.up || t.state != 'done' || !_announced.add(t)) continue;
      final l = context.l;
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l.filesDownloaded(t.name)),
            action: SnackBarAction(label: l.filesShare, onPressed: () => widget.shareFile(t.local)),
          ),
        );
    }
  }

  Future<void> _try(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(filesErrorText(context.l, e))));
    }
  }

  /// A name typed for a file or folder; null when cancelled.
  Future<String?> _askName(String title, String label, String action, {String initial = ''}) => showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, label: label, action: action, initial: initial),
  );

  Future<void> _newFolder() async {
    final l = context.l;
    final name = await _askName(l.filesNewFolder, l.filesFolderName, l.filesCreate);
    if (name != null) await _try(() => s.mkdir(name));
  }

  Future<void> _rename(RemoteEntry e) async {
    final l = context.l;
    final name = await _askName(l.filesRename, l.filesNewName, l.filesRename, initial: e.name);
    if (name != null && name != e.name) await _try(() => s.rename(e, name));
  }

  Future<void> _delete(RemoteEntry e) async {
    final l = context.l;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.filesDeleteAsk(e.name)),
        content: e.dir ? Text(l.filesDeleteFolderHint) : null,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.filesDelete)),
        ],
      ),
    );
    if (ok == true) await _try(() => s.remove(e));
  }

  Future<void> _download(RemoteEntry e) => _try(() async {
    // A name from the server is one name here, never a path.
    var name = e.name.replaceAll(RegExp(r'[/\\\x00]'), '_');
    if (name == '.' || name == '..') name = '_';
    final dir = '${await widget.downloads()}/${DateTime.now().microsecondsSinceEpoch}';
    await s.download(e, '$dir/$name');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l.filesDownloading(e.name))));
  });

  Future<void> _upload() => _try(() async {
    final files = await widget.pickFiles();
    for (final f in files) {
      await s.upload(f.path, f.name);
    }
  });

  Future<void> _save(FileTransfer t) => _try(() async {
    final l = context.l;
    final messenger = ScaffoldMessenger.of(context);
    if (await File(t.local).length() > saveLimit) {
      messenger.showSnackBar(SnackBar(content: Text(l.filesTooBigToSave)));
      return;
    }
    if (await widget.saveFile(t.local, t.name)) messenger.showSnackBar(SnackBar(content: Text(l.filesSaved)));
  });

  /// What can be done with an entry, for its menu and its long press.
  List<(IconData, String, VoidCallback)> _actions(RemoteEntry e) {
    final l = context.l;
    return [
      if (!e.dir) (Icons.download, l.filesDownload, () => _download(e)),
      (Icons.drive_file_rename_outline, l.filesRename, () => _rename(e)),
      (Icons.delete_outline, l.filesDelete, () => _delete(e)),
    ];
  }

  void _menu(RemoteEntry e) => showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          for (final (icon, label, onTap) in _actions(e))
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(context);
                onTap();
              },
            ),
        ],
      ),
    ),
  );

  void _showTransfers() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TransfersSheet(session: s, onSave: _save, onShare: (t) => widget.shareFile(t.local)),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final active = s.transfers.where((t) => t.active).length;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.title),
            actions: [
              if (s.connected) ...[
                IconButton(
                  tooltip: l.filesTransfers,
                  onPressed: s.transfers.isEmpty ? null : _showTransfers,
                  icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.swap_vert)),
                ),
                IconButton(
                  tooltip: l.filesNewFolder,
                  onPressed: _newFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              ],
              IconButton(
                tooltip: l.disconnect,
                onPressed: () => disconnectService(context, s),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          floatingActionButton: s.connected
              ? FloatingActionButton(tooltip: l.filesUpload, onPressed: _upload, child: const Icon(Icons.upload))
              : null,
          body: s.connected ? _browser(context) : _StateCard(session: s),
        );
      },
    );
  }

  Widget _browser(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final parent = s.parent;
    final date = DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm();
    return Column(
      children: [
        Material(
          color: cs.surfaceContainer,
          child: Row(
            children: [
              IconButton(
                tooltip: l.filesUp,
                onPressed: parent == null || s.loading ? null : () => s.list(parent),
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Text(s.path, style: const TextStyle(fontFamily: 'monospace')),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        SizedBox(height: 2, child: s.loading ? const LinearProgressIndicator() : null),
        if (s.listError != null)
          ListTile(
            leading: Icon(Icons.error_outline, color: cs.error),
            title: Text(l.filesListFailed),
            subtitle: Text(filesErrorText(l, ClientsError(s.listError!))),
            trailing: TextButton(onPressed: () => s.list(), child: Text(l.tryAgain)),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => s.list(),
            child: s.entries.isEmpty && !s.loading
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(48),
                        child: Text(
                          l.filesEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: s.entries.length,
                    itemBuilder: (context, i) {
                      final e = s.entries[i];
                      return ListTile(
                        leading: Icon(_icon(e), color: e.dir ? cs.primary : cs.onSurfaceVariant),
                        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [if (!e.dir) fileSize(e.size), date.format(e.modified)].join(' · '),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        onTap: e.dir ? () => s.list(s.child(e.name)) : () => _menu(e),
                        onLongPress: () => _menu(e),
                        trailing: PopupMenuButton<VoidCallback>(
                          onSelected: (f) => f(),
                          itemBuilder: (_) => [
                            for (final (icon, label, onTap) in _actions(e))
                              PopupMenuItem(
                                value: onTap,
                                child: ListTile(
                                  leading: Icon(icon),
                                  title: Text(label),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// A file's icon by its kind.
IconData _icon(RemoteEntry e) {
  if (e.dir) return e.link ? Icons.folder_special_outlined : Icons.folder;
  if (e.link) return Icons.link;
  final dot = e.name.lastIndexOf('.');
  final ext = dot < 0 ? '' : e.name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'heic' || 'svg' => Icons.image_outlined,
    'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => Icons.movie_outlined,
    'mp3' || 'flac' || 'wav' || 'ogg' || 'm4a' || 'opus' => Icons.audio_file_outlined,
    'zip' || 'tar' || 'gz' || 'tgz' || 'xz' || 'bz2' || '7z' || 'rar' || 'zst' => Icons.folder_zip_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'txt' ||
    'md' ||
    'log' ||
    'csv' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'toml' ||
    'conf' ||
    'ini' => Icons.description_outlined,
    'sh' || 'py' || 'go' || 'rs' || 'js' || 'ts' || 'dart' || 'c' || 'h' || 'cpp' || 'java' || 'kt' => Icons.code,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// A name for a new folder or a rename.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.label, required this.action, required this.initial});
  final String title, label, action, initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // The name without its extension is selected, to type over.
    final dot = widget.initial.lastIndexOf('.');
    _name.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : widget.initial.length);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid {
    final n = _name.text.trim();
    return n.isNotEmpty && n != '.' && n != '..' && !n.contains('/') && !n.contains('\x00');
  }

  void _done() {
    if (_valid) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: _name.text.contains('/') ? l.filesBadName : null,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _done(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _valid ? _done : null, child: Text(widget.action)),
      ],
    );
  }
}

/// The transfers, newest first, with their progress and what to do.
class _TransfersSheet extends StatelessWidget {
  const _TransfersSheet({required this.session, required this.onSave, required this.onShare});
  final FilesSession session;
  final void Function(FileTransfer) onSave, onShare;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(l.filesTransfers, style: Theme.of(context).textTheme.titleMedium),
                trailing: TextButton(
                  onPressed: session.transfers.any((t) => !t.active) ? session.clearEnded : null,
                  child: Text(l.filesClearEnded),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in session.transfers)
                      ListTile(
                        leading: Icon(t.up ? Icons.upload : Icons.download),
                        title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (t.active) ...[
                              const SizedBox(height: 4),
                              LinearProgressIndicator(value: t.state == 'running' ? t.progress : null),
                              const SizedBox(height: 4),
                            ],
                            Text(switch (t.state) {
                              'waiting' => l.filesWaiting,
                              'running' => l.filesProgress(fileSize(t.done), fileSize(t.total)),
                              'done' => l.filesDone,
                              'cancelled' => l.filesCancelled,
                              _ => filesErrorText(l, ClientsError(t.error ?? '')),
                            }, style: TextStyle(color: t.state == 'failed' ? cs.error : cs.onSurfaceVariant)),
                          ],
                        ),
                        trailing: t.active
                            ? IconButton(
                                tooltip: l.cancel,
                                onPressed: () => session.cancel(t),
                                icon: const Icon(Icons.close),
                              )
                            : !t.up && t.state == 'done'
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: l.filesShare,
                                    onPressed: () => onShare(t),
                                    icon: const Icon(Icons.share),
                                  ),
                                  IconButton(
                                    tooltip: l.save,
                                    onPressed: () => onSave(t),
                                    icon: const Icon(Icons.save_alt),
                                  ),
                                ],
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Connecting, or why it is not connected, with what to do.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.session});
  final FilesSession session;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final s = session;
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: s.state == 'connecting'
                ? [const CircularProgressIndicator(), const SizedBox(height: 16), Text(l.connecting)]
                : [
                    Icon(s.state == 'failed' ? Icons.error_outline : Icons.link_off, size: 40, color: cs.error),
                    const SizedBox(height: 12),
                    Text(serviceErrorText(l, s.error), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => retryService(context, s), child: Text(l.tryAgain)),
                  ],
          ),
        ),
      ),
    );
  }
}
