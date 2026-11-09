// One known host: open its desktop or its AI, its live status, the routes
// to it and what is saved for it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/model.dart';
import '../ai/ai_page.dart';
import '../shell/app.dart';
import 'device_widgets.dart';
import 'home_page.dart';

class DeviceDetail extends StatelessWidget {
  const DeviceDetail({super.key, required this.deviceId, this.embedded = false});
  final String deviceId;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final l = context.l;
    return ListenableBuilder(
      listenable: state.engine,
      builder: (context, _) {
        final status = state.engine.status;
        final host = status.host(deviceId);
        if (host == null) {
          return Scaffold(appBar: embedded ? null : AppBar(), body: Center(child: Text(l.deviceGone)));
        }
        final body = _Body(host: host, status: status);
        if (embedded) return Material(child: SafeArea(child: body));
        return Scaffold(appBar: AppBar(title: Text(host.title)), body: SafeArea(top: false, child: body));
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.host, required this.status});
  final RecentHost host;
  final Status status;

  Future<void> _confirm(BuildContext context, String title, String body, Future<void> Function() then) async {
    final l = context.l;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.ok)),
        ],
      ),
    );
    if (ok == true) {
      try {
        await then();
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final engine = AppScope.of(context).engine;
    final online = hostOnline(status, host.deviceId);
    final reach = reachText(l, status, host.deviceId);
    final w = status.watched(host.deviceId);
    final services = w?.services ?? const <String>[];
    final about = [host.about.maker, host.about.model].where((s) => s.isNotEmpty).join(' ');

    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(title, style: tt.titleSmall?.copyWith(color: cs.primary))),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: cs.surfaceContainerLow,
            child: Column(children: children),
          ),
        ],
      ),
    );

    final prefer = host.prefer;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(18)),
              child: Icon(osIcon(host.about.os), size: 28, color: cs.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(host.title, style: tt.headlineSmall),
                  Text(formatId(host.deviceId), style: TextStyle(fontFamily: 'monospace', color: cs.onSurfaceVariant)),
                  Text(
                    [reach ?? l.filterOffline, if (about.isNotEmpty) about].join(' · '),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => openDesktop(context, host.deviceId),
                icon: const Icon(Icons.desktop_windows_outlined),
                label: Text(l.openDesktop),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AiPage(deviceId: host.deviceId)),
              ),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(l.aiTask),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (service, icon, label) in [
              ('ssh', Icons.terminal, l.serviceSsh),
              ('rdp', Icons.window_outlined, l.serviceRdp),
              ('vnc', Icons.screen_share_outlined, l.serviceVnc),
            ])
              ActionChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.notInThisBuild)));
                },
                side: services.contains(service) ? BorderSide(color: cs.primary) : null,
              ),
          ],
        ),
        if (w != null && w.live)
          section(l.sectionStatus, [
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: HostBars(watched: w)),
            if (w.gpu != null) ListTile(dense: true, title: Text(l.statGpu), trailing: Text('${w.gpu!.round()}%')),
            if (w.battery != null)
              ListTile(
                dense: true,
                title: Text(l.statBattery),
                trailing: Text('${w.battery!['percent']}%${w.battery!['charging'] == true ? ' ⚡' : ''}'),
              ),
            ListTile(dense: true, title: Text(l.statUptime), trailing: Text(_uptime(w.uptime))),
          ])
        else if (w != null && w.state == 'no-credential')
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(l.statusNeedsSignIn, style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        section(l.sectionRoutes, [
          RadioGroup<String>(
            groupValue: prefer,
            onChanged: (v) => engine.act<Object?>('routes.set', {'device_id': host.deviceId, 'prefer': v ?? ''}),
            child: Column(
              children: [
                RadioListTile<String>(value: '', title: Text(l.routeAuto), subtitle: Text(l.routeAutoHint)),
                RadioListTile<String>(
                  value: 'network',
                  title: Text(l.routeNetwork),
                  subtitle: Text(reachText(l, status, host.deviceId) ?? l.filterOffline),
                ),
                for (final r in host.routes)
                  RadioListTile<String>(
                    value: r.address,
                    title: Text(r.address),
                    subtitle: Text(switch (r.probe?['state']) {
                      'ok' => '${l.routeOk}${r.probe?['rtt_ms'] == null ? '' : ' · ${r.probe!['rtt_ms']} ms'}',
                      null => '',
                      final s => failureText(l, '$s'),
                    }),
                    secondary: IconButton(
                      tooltip: l.remove,
                      icon: const Icon(Icons.close),
                      onPressed: () => engine.act<Object?>('routes.set', {'device_id': host.deviceId, 'remove': r.address}),
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l.routeAdd),
            onTap: () async {
              final address = await _ask(context, l.routeAdd, l.routeAddHint);
              if (address == null || address.isEmpty) return;
              try {
                await engine.act<Object?>('routes.set', {'device_id': host.deviceId, 'add': address});
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
              }
            },
          ),
        ]),
        section(l.sectionSignIn, [
          ListTile(
            leading: const Icon(Icons.password),
            title: Text(l.savedPassword),
            subtitle: Text(host.savedPassword ? l.saved : l.notSaved),
            trailing: host.savedPassword
                ? TextButton(
                    onPressed: () => engine.act<Object?>('credentials.forget', {'device_id': host.deviceId, 'service': 'password'}),
                    child: Text(l.forget),
                  )
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(l.signInKey),
            subtitle: Text(host.saved['key'] == true ? l.keyAdmitted : l.notSaved),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: Text(l.forgetIdentity),
            subtitle: Text(l.forgetIdentityHint),
            onTap: () => _confirm(context, l.forgetIdentity, l.forgetIdentityHint, () async {
              await engine.act<Object?>('host.forget', {'device_id': host.deviceId});
            }),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: cs.error),
            title: Text(l.removeDevice, style: TextStyle(color: cs.error)),
            onTap: () => _confirm(context, l.removeDevice, l.removeDeviceHint(host.title), () async {
              await engine.act<Object?>('device.remove', {'device_id': host.deviceId});
              if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
            }),
          ),
        ]),
        if (!online)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(l.offlineHint, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ),
      ],
    );
  }

  static String _uptime(int s) {
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return d > 0 ? '${d}d ${h}h' : '${h}h ${m}m';
  }
}

Future<String?> _ask(BuildContext context, String title, String hint) {
  final l = context.l;
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(l.ok)),
      ],
    ),
  ).whenComplete(() => unawaited(Future<void>.delayed(const Duration(seconds: 1), c.dispose)));
}
