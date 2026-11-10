// The sessions open from this phone: back to one, or end it.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/sessions.dart';
import '../../data/services.dart';
import '../ai/ai_page.dart';
import '../shell/app.dart';
import '../services/service_open.dart';
import '../viewer/clip_history.dart';
import '../viewer/viewer_page.dart';
import 'device_widgets.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final sessions = AppScope.of(context).sessions;
    final services = AppScope.of(context).services;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([sessions, services]),
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Row(
                children: [
                  Expanded(child: Text(l.navSessions, style: Theme.of(context).textTheme.headlineSmall)),
                  IconButton(
                    key: const ValueKey('clipHistoryAll'),
                    tooltip: l.clipHistory,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ClipHistoryPage())),
                    icon: const Icon(Icons.content_paste_search),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (sessions.open.isEmpty && services.open.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Column(
                    children: [
                      Icon(Icons.cast_outlined, size: 56, color: cs.outline),
                      const SizedBox(height: 12),
                      Text(l.noSessions, style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              for (final s in sessions.open)
                ListenableBuilder(
                  listenable: s,
                  builder: (context, _) => Card(
                    elevation: 0,
                    color: cs.surfaceContainerLow,
                    child: ListTile(
                      leading: Icon(switch (s.kind) {
                        SessionKind.ai => Icons.auto_awesome_outlined,
                        SessionKind.nanokvm => Icons.usb,
                        SessionKind.wake => Icons.light_mode_outlined,
                        SessionKind.desktop => osIcon(s.peer.os),
                      }),
                      title: Text(s.title),
                      subtitle: Text([
                        switch (s.kind) {
                          SessionKind.ai => l.aiTask,
                          SessionKind.nanokvm => l.nanokvm,
                          SessionKind.wake => l.actionWake,
                          SessionKind.desktop => l.desktop,
                        },
                        switch (s.state) {
                          'connected' => l.stateConnected,
                          'connecting' => l.connecting,
                          'confirming' => l.stateConfirming,
                          'reconnecting' => l.reconnecting,
                          'closed' => l.sessionEnded,
                          _ => failureText(l, s.failure),
                        },
                      ].join(' · ')),
                      trailing: IconButton(tooltip: l.disconnect, onPressed: s.close, icon: const Icon(Icons.close)),
                      onTap: s.kind == SessionKind.wake ? null : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => s.kind == SessionKind.ai ? AiPage(deviceId: s.deviceId) : ViewerPage(session: s),
                        ),
                      ),
                    ),
                  ),
                ),
              // SSH, files, Remote Desktop and VNC kept open.
              for (final s in services.open)
                Card(
                  key: ValueKey('service${s.id}'),
                  elevation: 0,
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: Icon(switch (s) {
                      FilesSession() => Icons.folder_outlined,
                      _ => switch (s.kind) {
                        ServiceKind.ssh => Icons.terminal,
                        ServiceKind.rdp => Icons.window_outlined,
                        ServiceKind.vnc => Icons.screen_share_outlined,
                      },
                    }),
                    title: Text(s.title),
                    subtitle: Text([
                      switch (s) {
                        FilesSession() => l.filesTitle,
                        _ => switch (s.kind) {
                          ServiceKind.ssh => l.serviceSsh,
                          ServiceKind.rdp => l.serviceRdp,
                          ServiceKind.vnc => l.serviceVnc,
                        },
                      },
                      s.connected ? l.stateConnected : l.connecting,
                    ].join(' · ')),
                    trailing: IconButton(tooltip: l.disconnect, onPressed: () => services.end(s), icon: const Icon(Icons.close)),
                    onTap: () => showService(context, s),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
