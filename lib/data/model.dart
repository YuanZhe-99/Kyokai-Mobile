// Typed views over the core's `status` (third_party/kyokai lib.rs `status`):
// thin wrappers that read the JSON maps lazily, so a field the core adds or
// drops never breaks the app.

import '../ui/keyboard/keys.dart';

typedef Json = Map<String, Object?>;

Json _map(Object? o) => o is Map ? o.cast<String, Object?>() : const {};
List<Json> _list(Object? o) => o is List ? o.map(_map).toList() : const [];
String _str(Object? o) => o == null ? '' : '$o';
int _int(Object? o) => o is num ? o.toInt() : 0;
double _num(Object? o) => o is num ? o.toDouble() : 0;

class Status {
  Status(this.raw);
  final Json raw;

  String get deviceId => _str(raw['device_id']);
  String get name => _str(raw['name']);
  String get persistence => _str(raw['persistence']);
  String get version => _str(raw['version']);
  String? get error => raw['error'] as String?;
  NetworkStatus get network => NetworkStatus(_map(raw['network']));
  List<SessionInfo> get sessions => _list(raw['sessions']).map(SessionInfo.new).toList();
  List<RecentHost> get recent => _list(raw['recent']).map(RecentHost.new).toList();
  List<Watched> get watching => _list(raw['watching']).map(Watched.new).toList();

  SessionInfo? session(int id) => sessions.where((s) => s.id == id).firstOrNull;
  RecentHost? host(String deviceId) => recent.where((r) => r.deviceId == deviceId).firstOrNull;
  Watched? watched(String deviceId) => watching.where((w) => w.deviceId == deviceId).firstOrNull;

  /// The network's view of a device: its path and latency, when online.
  NetDevice? netDevice(String deviceId) => network.devices.where((d) => d.deviceId == deviceId).firstOrNull;
}

class NetworkStatus {
  NetworkStatus(this.raw);
  final Json raw;
  String get state => _str(raw['state']);
  String get error => _str(raw['error']);
  String get address => _str(raw['address']);
  String get nat => _str(raw['nat']);
  List<NetDevice> get devices => _list(raw['devices']).map(NetDevice.new).toList();
  List<Json> get networks => _list(raw['networks']);
}

class NetDevice {
  NetDevice(this.raw);
  final Json raw;
  String get deviceId => _str(raw['device_id']);
  String get path => _str(raw['path']);
  int? get latencyMs => raw['latency_ms'] is num ? _int(raw['latency_ms']) : null;
  String get name => _str(raw['name']);
  bool get lan => raw['lan'] == true;
}

class About {
  About(this.raw);
  final Json raw;
  String get name => _str(raw['name']);
  String get maker => _str(raw['maker']);
  String get model => _str(raw['model']);

  /// `windows`, `macos`, or empty for Linux (and unknown).
  String get os => _str(raw['os']);

  HostOs get hostOs => switch (os) {
    'windows' => HostOs.windows,
    'macos' => HostOs.macos,
    _ => HostOs.linux,
  };
}

/// A known host: what the home screen lists.
class RecentHost {
  RecentHost(this.raw);
  final Json raw;
  String get deviceId => _str(raw['device_id']);
  int get last => _int(raw['last']);
  About get about => About(_map(raw['about']));
  bool get savedPassword => raw['saved_password'] == true;
  List<Route> get routes => _list(raw['routes']).map(Route.new).toList();
  Json get networkRoute => _map(raw['network_route']);
  String get prefer => _str(raw['prefer']);
  List<String> get features => (raw['features'] as List?)?.map((e) => '$e').toList() ?? const [];
  Json get saved => _map(raw['saved']);
  bool has(String feature) => features.contains(feature);

  /// The name to show: the host's own, else its Device ID.
  String get title => about.name.isNotEmpty ? about.name : formatId(deviceId);
}

class Route {
  Route(this.raw);
  final Json raw;
  String get address => _str(raw['address']);
  int? get rttMs => raw['rtt_ms'] is num ? _int(raw['rtt_ms']) : null;
  Json? get probe => raw['probe'] is Map ? _map(raw['probe']) : null;
  bool get ok => probe?['state'] == 'ok';
}

class Watched {
  Watched(this.raw);
  final Json raw;
  String get deviceId => _str(raw['device_id']);
  String get state => _str(raw['state']);
  Json? get sample => raw['sample'] is Map ? _map(raw['sample']) : null;
  int get receivedAt => _int(raw['received_at']);

  /// Live: a sample newer than 15 s.
  bool get live => sample != null && DateTime.now().millisecondsSinceEpoch - receivedAt < 15000;

  double? get cpu => sample == null ? null : _num(_map(sample!['cpu'])['usage']);
  double? _ratio(String key) {
    final m = _map(sample?[key]);
    final total = _num(m['total']);
    return total <= 0 ? null : _num(m['used']) / total;
  }

  double? get memory => _ratio('memory');
  double? get disk => _ratio('disk');
  double? get gpu => sample?['gpu'] is Map ? _num(_map(sample!['gpu'])['usage']) : null;
  Json? get battery => sample?['battery'] is Map ? _map(sample!['battery']) : null;
  List<String> get services => (sample?['services'] as List?)?.map((e) => '$e').toList() ?? const [];
  bool get ai => sample?['ai'] == true;
  int get uptime => _int(sample?['uptime_s']);
}

class SessionInfo {
  SessionInfo(this.raw);
  final Json raw;
  int get id => _int(raw['id']);
  String get role => _str(raw['role']);
  String get deviceId => _str(raw['device_id']);
  String get state => _str(raw['state']);
  Object? get failure => raw['failure'];
  List<String> get granted => (raw['granted'] as List?)?.map((e) => '$e').toList() ?? const [];
  About get peer => About(_map(raw['peer']));
  String? get service => raw['service'] as String?;
  String? get route => raw['route'] as String?;
  bool get controller => role == 'controller';
  bool get ended => state == 'closed' || state == 'failed';

  /// The failure as one word: `password`, `denied`, `unreachable`, …
  String? get failureCode => switch (failure) {
    null => null,
    final String s => s,
    final Map<dynamic, dynamic> m => '${m['refused'] ?? m.values.firstOrNull}',
    final o => '$o',
  };
}

/// A Device ID as people read it: `482 916 735`.
String formatId(String id) =>
    id.length == 9 ? '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}' : id;

/// A Device ID typed with spaces or dashes, or null when it is not one.
String? parseId(String text) {
  final digits = text.replaceAll(RegExp(r'[\s\-]'), '');
  return RegExp(r'^\d{9}$').hasMatch(digits) ? digits : null;
}
