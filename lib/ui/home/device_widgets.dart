// Pieces of the device list: a host's card, its live bars, the network chip
// and the words for why a connection failed.

import 'package:flutter/material.dart';

import '../../data/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../shell/app.dart';

/// Online: the network routes to it, a route to it answers, or its live
/// stats arrive.
bool hostOnline(Status s, String deviceId) =>
    s.netDevice(deviceId) != null ||
    (s.host(deviceId)?.routes.any((r) => r.ok) ?? false) ||
    (s.watched(deviceId)?.live ?? false);

/// How the host is reached now: `Direct · 8 ms`, `Relayed · 46 ms`,
/// `LAN · 2 ms`, or null when offline.
String? reachText(AppLocalizations l, Status s, String deviceId) {
  final d = s.netDevice(deviceId);
  if (d != null) {
    final how = d.lan ? l.pathLan : (d.path == 'relay' ? l.pathRelay : l.pathDirect);
    return d.latencyMs == null ? how : '$how · ${d.latencyMs} ms';
  }
  final r = s.host(deviceId)?.routes.where((r) => r.ok).firstOrNull;
  if (r != null) {
    final rtt = r.probe?['rtt_ms'] ?? r.rttMs;
    return rtt == null ? l.pathAddress(r.address) : '${l.pathAddress(r.address)} · $rtt ms';
  }
  if (s.watched(deviceId)?.live ?? false) return l.filterOnline;
  return null;
}

IconData osIcon(String os) => switch (os) {
  'windows' => Icons.desktop_windows_outlined,
  'macos' => Icons.laptop_mac_outlined,
  _ => Icons.computer_outlined,
};

String failureText(AppLocalizations l, String? code) => switch (code) {
  'password' => l.failPassword,
  'denied' => l.failDenied,
  'timeout' => l.failTimeout,
  'busy' => l.failBusy,
  'rate-limited' => l.failRateLimited,
  'absent' => l.failAbsent,
  'service-down' => l.failServiceDown,
  'unreachable' => l.failUnreachable,
  'wrong-device' => l.failWrongDevice,
  'key-changed' => l.failKeyChanged,
  'incompatible' => l.failIncompatible,
  'broken' => l.failBroken,
  'unsupported' => l.failUnsupported,
  'self' => l.failSelf,
  null || '' => l.failUnknown,
  final other => other,
};

class NetworkChip extends StatelessWidget {
  const NetworkChip({super.key, required this.network});
  final NetworkStatus network;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final (label, bg, fg) = switch (network.state) {
      'online' => (l.netOnline, cs.secondaryContainer, cs.onSecondaryContainer),
      'connecting' => (l.netConnecting, cs.surfaceContainerHighest, cs.onSurfaceVariant),
      'error' => (l.netError, cs.errorContainer, cs.onErrorContainer),
      _ => (l.netOff, cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Tooltip(
      message: network.state == 'error' ? network.error : network.address,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}

class StatBar extends StatelessWidget {
  const StatBar({super.key, required this.label, required this.value});
  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = value;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const Spacer(),
              Text(v == null ? '–' : '${(v * 100).round()}%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: v ?? 0, minHeight: 6, backgroundColor: cs.surfaceContainerHighest),
          ),
        ],
      ),
    );
  }
}

/// CPU, memory and disk, when the host's live stats arrive.
class HostBars extends StatelessWidget {
  const HostBars({super.key, required this.watched});
  final Watched? watched;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final w = watched;
    if (w == null || !w.live) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          StatBar(label: l.statCpu, value: w.cpu == null ? null : w.cpu! / 100),
          const SizedBox(width: 12),
          StatBar(label: l.statMemory, value: w.memory),
          const SizedBox(width: 12),
          StatBar(label: l.statDisk, value: w.disk),
        ],
      ),
    );
  }
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.host, required this.status, required this.onTap, this.selected = false, this.onWake});
  final RecentHost host;
  final Status status;
  final VoidCallback onTap;

  /// Wakes the host's screen (home's quick action); null shows no button.
  final VoidCallback? onWake;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final online = hostOnline(status, host.deviceId);
    final reach = reachText(l, status, host.deviceId);
    final watched = status.watched(host.deviceId);
    final open = status.sessions.where((s) => s.deviceId == host.deviceId && s.controller && !s.ended).length;
    return Card(
      elevation: 0,
      color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: online ? cs.primaryContainer : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(osIcon(host.about.os), color: online ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(host.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          formatId(host.deviceId),
                          style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (onWake != null)
                    IconButton(
                      key: ValueKey('wake${host.deviceId}'),
                      tooltip: l.actionWake,
                      visualDensity: VisualDensity.compact,
                      onPressed: onWake,
                      icon: const Icon(Icons.light_mode_outlined, size: 20),
                    ),
                  if (open > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.cast_connected, size: 18, color: cs.primary),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: online ? cs.tertiaryContainer : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      reach ?? l.filterOffline,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: online ? cs.onTertiaryContainer : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              HostBars(watched: watched),
            ],
          ),
        ),
      ),
    );
  }
}
