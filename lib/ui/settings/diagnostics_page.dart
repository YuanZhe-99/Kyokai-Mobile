// Diagnostics: the facts a bug report needs (build, core, decoders,
// network), the video details overlay, and sharing the logs.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../build_info.dart';
import '../../data/app_state.dart';
import '../../data/log.dart';
import '../shell/app.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  static String report(AppState state) {
    final e = state.engine;
    final s = e.status;
    final lines = <String>[
      'Kyokai-Mobile $appVersion (build $buildNumber, $buildCommit, $buildTime)',
      'core: ${s.version.isEmpty ? '-' : s.version}, ABI ${s.raw['abi'] ?? '-'}, started ${e.started}',
      if (e.error != null) 'start error: ${e.error}',
      'device: ${e.device['model']} · Android ${e.device['android']} (SDK ${e.device['sdk']}) · ${e.device['abis']}',
      'device id: ${s.deviceId} · name: ${s.name}',
      'secrets: ${s.persistence}',
      'serve: ${s.raw['serve']}',
      'network: ${s.network.state} ${s.network.address} nat ${s.network.nat} · ${s.network.networks.length} networks, ${s.network.devices.length} devices',
      if (s.network.error.isNotEmpty) 'network error: ${s.network.error}',
      'decoders: ${e.decoders.map((d) => '${d['codec']}=${d['name']}${d['hardware'] == true ? '(hw)' : ''} ${d['max_width']}x${d['max_height']}').join(', ')}',
      'sessions: ${state.sessions.open.map((x) => '${x.id}:${x.kind.name}:${x.state}${x.failure == null ? '' : '(${x.failure})'}:${x.videoStart['codec'] ?? '-'}:${x.texture?.decoder ?? '-'}').join(' ')}',
      'known hosts: ${s.recent.length}',
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.diagnostics)),
      body: ListenableBuilder(
        listenable: Listenable.merge([state.engine, state.prefs]),
        builder: (context, _) {
          final text = report(state);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: Text(l.showVideoDetails),
                subtitle: Text(l.showVideoDetailsHint),
                value: state.prefs.overlay,
                onChanged: (v) => state.prefs.overlay = v,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Log.share(text),
                icon: const Icon(Icons.share_outlined),
                label: Text(l.shareLogs),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
                },
                icon: const Icon(Icons.copy),
                label: Text(l.copyReport),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final raw = const JsonEncoder.withIndent('  ').convert(state.engine.status.raw);
                  await Clipboard.setData(ClipboardData(text: raw));
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
                },
                icon: const Icon(Icons.data_object),
                label: Text(l.copyStatus),
              ),
              const SizedBox(height: 16),
              Text(l.logsPrivacy, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }
}
