// EasyTier networks: up to 8, all joined at once, on standard EasyTier
// servers (third_party/kyokai doc networking.md).

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/model.dart';
import '../shell/app.dart';

class NetworksPage extends StatefulWidget {
  const NetworksPage({super.key});

  @override
  State<NetworksPage> createState() => _NetworksPageState();
}

class _NetworksPageState extends State<NetworksPage> {
  Json _p = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final r = await AppScope.of(context).engine.call<Map<String, Object?>>('network.profiles');
    if (mounted) setState(() => _p = r);
  }

  Future<void> _call(String method, Json params) async {
    try {
      final r = await AppScope.of(context).engine.act<Map<String, Object?>>(method, params);
      if (mounted) setState(() => _p = r);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _edit([Json? profile]) async {
    final r = await showDialog<Json>(context: context, builder: (_) => NetworkProfileDialog(profile: profile));
    if (r != null) await _call('network.profile.set', r);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final profiles = ((_p['profiles'] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();
    return Scaffold(
      appBar: AppBar(title: Text(l.networks)),
      floatingActionButton: profiles.length < 8
          ? FloatingActionButton.extended(onPressed: _edit, icon: const Icon(Icons.add), label: Text(l.networkAdd))
          : null,
      body: ListenableBuilder(
        listenable: AppScope.of(context).engine,
        builder: (context, _) {
          final live = AppScope.of(context).engine.status.network.networks;
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(padding: const EdgeInsets.all(16), child: Text(l.networksExplain, style: TextStyle(color: cs.onSurfaceVariant))),
              for (final p in profiles)
                Builder(builder: (context) {
                  final st = live.where((n) => n['id'] == p['id']).firstOrNull;
                  final state = '${st?['state'] ?? (p['joined'] == true ? 'connecting' : 'off')}';
                  final devices = (st?['devices'] as List?)?.length ?? 0;
                  return ListTile(
                    leading: Icon(Icons.hub, color: state == 'online' ? cs.primary : cs.outline),
                    title: Text('${(p['label'] as String?)?.isNotEmpty == true ? p['label'] : p['name']}'),
                    subtitle: Text([
                      state,
                      if (st?['address'] != null) '${st!['address']}',
                      if (state == 'online') l.networkDevices(devices),
                      if (p['weak_secret'] == true) l.weakSecret,
                    ].join(' · ')),
                    trailing: Switch(
                      value: p['joined'] == true,
                      onChanged: (v) => _call('network.profile.set', {'id': p['id'], 'joined': v}),
                    ),
                    onTap: () => _edit(p),
                    onLongPress: () => _call('network.profile.remove', {'id': p['id']}),
                  );
                }),
              const Divider(),
              SwitchListTile(
                title: Text(l.directPaths),
                subtitle: Text(l.directPathsHint),
                value: _p['direct'] == true,
                onChanged: (v) => _call('network.direct', {'direct': v}),
              ),
              SwitchListTile(
                title: Text(l.latencyFirst),
                subtitle: Text(l.latencyFirstHint),
                value: _p['latency_first'] == true,
                onChanged: (v) => _call('network.latency_first', {'latency_first': v}),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A network's label, servers, name and secret; pops the profile to save.
class NetworkProfileDialog extends StatefulWidget {
  const NetworkProfileDialog({super.key, this.profile});
  final Json? profile;

  @override
  State<NetworkProfileDialog> createState() => NetworkProfileDialogState();
}

class NetworkProfileDialogState extends State<NetworkProfileDialog> {
  late final _label = TextEditingController(text: '${widget.profile?['label'] ?? ''}');
  /// One field a server: a phone's keyboard has no new line in a URL field,
  /// so a server list cannot be typed as lines.
  late final List<TextEditingController> _servers = [
    for (final s in (widget.profile?['servers'] as List?) ?? const ['tcp://public.easytier.cn:11010'])
      TextEditingController(text: '$s'),
  ];
  final List<FocusNode> _serverFocus = [];

  FocusNode _focusFor(int i) {
    while (_serverFocus.length <= i) {
      _serverFocus.add(FocusNode());
    }
    return _serverFocus[i];
  }

  void _addServer() {
    setState(() => _servers.add(TextEditingController()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFor(_servers.length - 1).requestFocus());
  }

  @override
  void dispose() {
    for (final c in _servers) {
      c.dispose();
    }
    for (final f in _serverFocus) {
      f.dispose();
    }
    super.dispose();
  }
  late final _name = TextEditingController(text: '${widget.profile?['name'] ?? ''}');
  final _secret = TextEditingController();
  bool _hide = true;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final editing = widget.profile != null;
    return AlertDialog(
      title: Text(editing ? l.networkEdit : l.networkAdd),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _label, decoration: InputDecoration(labelText: l.networkLabel)),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(l.networkServers, style: Theme.of(context).textTheme.labelLarge),
            ),
            for (var i = 0; i < _servers.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  key: ValueKey('server$i'),
                  controller: _servers[i],
                  focusNode: _focusFor(i),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  // Enter on the last one adds the next server.
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => i == _servers.length - 1 ? _addServer() : _focusFor(i + 1).requestFocus(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l.networkServerHint,
                    suffixIcon: _servers.length > 1
                        ? IconButton(
                            tooltip: l.remove,
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setState(() {
                              _servers.removeAt(i).dispose();
                              if (i < _serverFocus.length) _serverFocus.removeAt(i).dispose();
                            }),
                          )
                        : null,
                  ),
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('serverAdd'),
                onPressed: _addServer,
                icon: const Icon(Icons.add),
                label: Text(l.networkServerAdd),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: InputDecoration(labelText: l.networkName)),
            const SizedBox(height: 12),
            TextField(
              controller: _secret,
              obscureText: _hide,
              decoration: InputDecoration(
                labelText: l.networkSecret,
                helperText: editing && widget.profile?['has_secret'] == true ? l.networkSecretKeep : null,
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _hide = !_hide),
                  icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () {
            // A pasted list in one field still splits.
            final servers = _servers
                .expand((c) => c.text.split(RegExp(r'[\s,]+')))
                .where((s) => s.isNotEmpty)
                .toList();
            Navigator.pop(context, <String, Object?>{
              if (editing) 'id': widget.profile!['id'],
              'label': _label.text.trim(),
              'servers': servers,
              'name': _name.text.trim(),
              if (_secret.text.isNotEmpty) 'secret': _secret.text,
            });
          },
          child: Text(l.save),
        ),
      ],
    );
  }
}
