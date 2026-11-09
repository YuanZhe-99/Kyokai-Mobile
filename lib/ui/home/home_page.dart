// Devices: connect by Device ID or address, and the known hosts as cards
// with their live status. A wide screen (MyApps-UI's split rule) shows the
// list beside the selected device's details.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:myapps_adaptive/myapps_adaptive.dart';

import '../../data/app_state.dart';
import '../../data/model.dart';
import '../../data/sessions.dart';
import '../shell/app.dart';
import '../viewer/viewer_page.dart';
import 'device_detail.dart';
import 'device_widgets.dart';

enum _Filter { all, online, offline }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _target = TextEditingController();
  _Filter _filter = _Filter.all;
  String? _selected;
  bool _connecting = false;

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final l = context.l;
    final state = AppScope.of(context);
    final text = _target.text.trim();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    var id = parseId(text);
    String? address;
    if (id == null) {
      // An IP address or a domain name: ask the device there who it is.
      setState(() => _connecting = true);
      try {
        final r = await state.engine.call<Map<String, Object?>>('session.identify', {'address': text});
        if (r['device_id'] is String) {
          id = r['device_id'] as String;
          address = text;
        } else {
          messenger.showSnackBar(SnackBar(content: Text(failureText(l, '${r['failure']}'))));
        }
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      } finally {
        if (mounted) setState(() => _connecting = false);
      }
    }
    if (id == null || !mounted) return;
    state.prefs.addRecent(text);
    await openDesktop(context, id, address: address);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.engine,
      builder: (context, _) {
        final status = state.engine.status;
        final hosts = status.recent;
        state.engine.watch(hosts.map((h) => h.deviceId).toList());
        final shown = hosts.where((h) {
          final online = hostOnline(status, h.deviceId);
          return switch (_filter) {
            _Filter.all => true,
            _Filter.online => online,
            _Filter.offline => !online,
          };
        }).toList();
        return LayoutBuilder(
          builder: (context, box) {
            final split = canSplitLayout(box.maxWidth, box.maxHeight);
            final selected = split ? (_selected ?? shown.firstOrNull?.deviceId) : null;
            final list = _list(context, status, shown, split ? selected : null);
            if (!split) return Scaffold(body: list);
            final host = selected == null ? null : status.host(selected);
            return Scaffold(
              body: Row(
                children: [
                  SizedBox(width: box.maxWidth < 900 ? 340 : 400, child: list),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: host == null
                        ? Center(child: Text(l.noDeviceSelected))
                        : DeviceDetail(key: ValueKey(host.deviceId), deviceId: host.deviceId, embedded: true),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _list(BuildContext context, Status status, List<RecentHost> hosts, String? selected) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final net = status.network;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    Expanded(child: Text(l.navDevices, style: Theme.of(context).textTheme.headlineSmall)),
                    NetworkChip(network: net),
                  ],
                ),
                const SizedBox(height: 12),
                SearchBar(
                  controller: _target,
                  hintText: l.connectHint,
                  leading: const Icon(Icons.search),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  trailing: [
                    if (_connecting)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      FilledButton(onPressed: _connect, child: Text(l.connect)),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: GestureDetector(
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: status.deviceId));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
                    },
                    child: Text(
                      l.thisDevice(formatId(status.deviceId)),
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final f in _Filter.values)
                      FilterChip(
                        label: Text(switch (f) {
                          _Filter.all => l.filterAll,
                          _Filter.online => l.filterOnline,
                          _Filter.offline => l.filterOffline,
                        }),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (hosts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.devices_other_outlined, size: 56, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(l.noDevices, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      net.state == 'off' ? l.noDevicesNoNetwork : l.noDevicesHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList.separated(
                itemCount: hosts.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final h = hosts[i];
                  return DeviceCard(
                    host: h,
                    status: status,
                    selected: selected == h.deviceId,
                    onTap: () {
                      if (selected != null) {
                        setState(() => _selected = h.deviceId);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => DeviceDetail(deviceId: h.deviceId)),
                        );
                      }
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens a desktop session to a host and shows its screen.
Future<void> openDesktop(BuildContext context, String deviceId, {String? address, String? route}) async {
  final state = AppScope.of(context);
  final nav = Navigator.of(context);
  final session = await state.sessions.connect(deviceId, address: address, route: route);
  if (!context.mounted) return;
  unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ViewerPage(session: session))));
}

/// Opens the AI link to a host (no picture) and shows its task.
Future<RemoteSession> openAi(BuildContext context, String deviceId) =>
    AppScope.of(context).sessions.connect(deviceId, kind: SessionKind.ai);
