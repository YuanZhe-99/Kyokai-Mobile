// The core, run in this process as Kyokai's engine runs it on a computer
// (third_party/kyokai/internal/engine): started once, its status polled,
// its leases renewed. A phone only controls, so it serves no one.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ffi.dart' as core;
import '../core/native.dart';
import 'log.dart';
import 'model.dart';

/// The Kyokai version this app's core is (sent to hosts in hellos).
const kyokaiVersion = '0.7.3';

class Engine extends ChangeNotifier {
  Status status = Status(const {});
  String? error;
  bool started = false;

  /// What this device decodes (`Video.decodable`), for diagnostics.
  List<Map<String, Object?>> decoders = const [];
  Map<String, Object?> device = const {};
  String stateDir = '';

  Timer? _tick;
  bool _busy = false;
  int _ticks = 0;

  /// Devices whose live stats the home screen wants (`watch.set`, ≤8).
  List<String> _watch = const [];

  /// Polls faster while a session is open or a screen asks for it.
  int _fast = 0;

  Future<void> begin() async {
    try {
      device = await Native.device();
      final base = await getApplicationSupportDirectory();
      stateDir = '${base.path}/kyokai';
      await Directory(stateDir).create(recursive: true);
      final key = await Native.masterKey();
      if (key == null) Log.error('engine', 'the Android Keystore cannot keep the secrets key: memory only');
      Map<String, Object?> first;
      try {
        first = await core.start({
          'version': kyokaiVersion,
          'state_dir': stateDir,
          'profile': '',
          'master_key': ?key,
        });
      } on core.CoreError catch (e) {
        if (!e.message.contains('already started')) rethrow;
        first = await _adopt();
      }
      status = Status(first);
      started = true;
      Log.info('engine', 'core started: ${status.deviceId}, ${status.persistence}');
      // The phone controls; it never lets anyone in.
      await core.call<Object?>('host.serve', {'serve': 'none'});
      decoders = await Native.decoders();
      final names = decoders.map((d) => '${d['codec']}').toList();
      if (names.isEmpty) names.add('h264');
      await core.call<Object?>('android.decoders', {'decode': names});
      Log.info('engine', 'decoders: $decoders');
      if (status.name.isEmpty) {
        final model = '${device['model'] ?? 'Android'}'.trim();
        await core.call<Object?>('device.set_name', {'name': model.length > 64 ? model.substring(0, 64) : model});
      }
      await refresh();
    } catch (e, st) {
      error = '$e';
      Log.error('engine', e, st);
      notifyListeners();
      return;
    }
    _tick = Timer.periodic(const Duration(milliseconds: 500), _onTick);
  }

  /// The core outlives the app's Flutter engine: when Android makes the
  /// activity again in the same process (a fold, the system taking back
  /// memory from the UI only), the core is still running. Its sessions
  /// belonged to the old screens, whose readers are gone: they are closed,
  /// and the core is used as it is.
  Future<Map<String, Object?>> _adopt() async {
    Log.info('engine', 'the core was already running: taking it over');
    final now = Status(await core.call<Map<String, Object?>>('status'));
    for (final s in now.sessions) {
      try {
        await core.call<Object?>('session.close', {'id': s.id});
      } catch (e) {
        Log.error('engine', e);
      }
    }
    return core.call<Map<String, Object?>>('status');
  }

  void _onTick(Timer t) {
    _ticks++;
    // Every 500 ms while busy, every 1.5 s otherwise.
    if (_fast > 0 || _ticks % 3 == 0) unawaited(refresh());
    if (_ticks % 20 == 1) unawaited(_renewWatch());
    if (_ticks % 120 == 1) unawaited(_probe());
  }

  /// Asks for quicker status while [on] (a dial, an open session).
  void hurry(bool on) => _fast = (_fast + (on ? 1 : -1)).clamp(0, 1 << 20);

  Future<void> refresh() async {
    if (_busy || !started) return;
    _busy = true;
    try {
      final r = await core.call<Map<String, Object?>>('status');
      status = Status(r);
      notifyListeners();
    } catch (e) {
      Log.error('status', e);
    } finally {
      _busy = false;
    }
  }

  /// Calls a core method and refreshes the status right after it.
  Future<T> act<T>(String method, [Object? params]) async {
    try {
      return await core.call<T>(method, params);
    } finally {
      unawaited(Future<void>.delayed(const Duration(milliseconds: 100), refresh));
    }
  }

  Future<T> call<T>(String method, [Object? params]) => core.call<T>(method, params);

  /// The hosts the home screen shows: their live stats are watched.
  void watch(List<String> devices) {
    final next = devices.take(8).toList();
    if (listEquals(next, _watch)) return;
    _watch = next;
    unawaited(_renewWatch());
  }

  Future<void> _renewWatch() async {
    if (!started) return;
    try {
      await core.call<Object?>('watch.set', {'devices': _watch});
    } catch (e) {
      Log.error('watch', e);
    }
  }

  Future<void> _probe() async {
    if (!started) return;
    final ids = status.recent.map((r) => r.deviceId).take(16).toList();
    if (ids.isEmpty) return;
    try {
      await core.call<Object?>('routes.probe', {'devices': ids});
    } catch (e) {
      Log.error('probe', e);
    }
  }

  /// Ends every session and stops the core (the app is going away).
  Future<void> end() async {
    _tick?.cancel();
    if (started) await core.stop();
    started = false;
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}
