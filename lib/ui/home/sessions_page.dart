// The sessions open from this phone: back to one, or end it.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/sessions.dart';
import '../ai/ai_page.dart';
import '../shell/app.dart';
import '../viewer/viewer_page.dart';
import 'device_widgets.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final sessions = AppScope.of(context).sessions;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: sessions,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Text(l.navSessions, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              if (sessions.open.isEmpty)
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
                      leading: Icon(s.kind == SessionKind.ai ? Icons.auto_awesome_outlined : osIcon(s.peer.os)),
                      title: Text(s.title),
                      subtitle: Text([
                        s.kind == SessionKind.ai ? l.aiTask : l.desktop,
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
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => s.kind == SessionKind.ai ? AiPage(deviceId: s.deviceId) : ViewerPage(session: s),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
