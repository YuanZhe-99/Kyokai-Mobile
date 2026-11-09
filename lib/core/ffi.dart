// The Kyokai core (third_party/kyokai/core/kyokai-core), loaded in this
// process through its C ABI, as Kyokai's engine loads it on a computer
// (third_party/kyokai/doc/en-us/architecture.md, "FFI"). The app is the
// engine and the GUI at once: calls go straight to the core, each on an
// isolate of its own so a slow one never holds up a frame.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';


/// The C ABI version this app speaks; the core refuses nothing, the app
/// refuses a core of another version.
const abiVersion = 8;

/// Packet kinds between the core and its GUI (`media::packet`).
abstract final class Packet {
  static const videoStart = 1;
  static const frame = 2;
  static const control = 3;
  static const stats = 4;
  static const aiTask = 5;
  static const aiError = 6;
  static const cursor = 7;
  static const displays = 8;
  static const actions = 9;
  static const aiDraft = 10;
  static const codecs = 11;
  static const audio = 12;
  static const clipboard = 13;
  static const input = 15;
  static const aiExport = 16;
}

/// An answer of the core's `{"ok": false, "error": …}`.
class CoreError implements Exception {
  CoreError(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef _ExchangeC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _Exchange =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// The library's exports. Each isolate looks them up once; the library
/// itself is loaded once per process.
final class _Lib {
  _Lib._(DynamicLibrary l)
    : abi = l.lookupFunction<Uint32 Function(), int Function()>('kyokai_abi_version'),
      start = l.lookupFunction<_ExchangeC, _Exchange>('kyokai_start'),
      call = l.lookupFunction<_ExchangeC, _Exchange>('kyokai_call'),
      free = l.lookupFunction<Void Function(Pointer<Uint8>, Size), void Function(Pointer<Uint8>, int)>(
        'kyokai_free',
      ),
      stop = l.lookupFunction<Void Function(), void Function()>('kyokai_stop'),
      mediaRead = l
          .lookupFunction<Int64 Function(Uint64, Pointer<Uint8>, Size, Uint32), int Function(int, Pointer<Uint8>, int, int)>(
            'kyokai_media_read',
          ),
      mediaWrite = l.lookupFunction<Int32 Function(Uint64, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>(
        'kyokai_media_write',
      );

  static final instance = _Lib._(DynamicLibrary.open('libkyokai_core.so'));

  final int Function() abi;
  final _Exchange start;
  final _Exchange call;
  final void Function(Pointer<Uint8>, int) free;
  final void Function() stop;
  final int Function(int, Pointer<Uint8>, int, int) mediaRead;
  final int Function(int, Pointer<Uint8>, int) mediaWrite;

  /// Passes one JSON document through an exchange export and decodes the
  /// answer's result.
  Object? exchange(_Exchange f, Object request) {
    final body = utf8.encode(jsonEncode(request));
    final input = malloc<Uint8>(body.length);
    final out = malloc<Pointer<Uint8>>();
    final outLen = malloc<Size>();
    try {
      input.asTypedList(body.length).setAll(0, body);
      if (f(input, body.length, out, outLen) != 0) {
        throw CoreError('the core refused the call');
      }
      final answer = utf8.decode(out.value.asTypedList(outLen.value));
      free(out.value, outLen.value);
      final doc = jsonDecode(answer) as Map<String, Object?>;
      if (doc['ok'] != true) throw CoreError('${doc['error']}');
      return doc['result'];
    } finally {
      malloc.free(input);
      malloc.free(out);
      malloc.free(outLen);
    }
  }
}

/// Starts the core: `{version, state_dir, profile}`, plus on Android the
/// secrets store's key, which the system's keystore guards.
/// Returns: the first status.
Future<Map<String, Object?>> start(Map<String, Object?> config) => Isolate.run(() {
  final lib = _Lib.instance;
  final abi = lib.abi();
  if (abi != abiVersion) throw CoreError('core ABI $abi, this app speaks $abiVersion');
  return lib.exchange(lib.start, config) as Map<String, Object?>;
});

/// Calls one of the core's methods (`{method, params}`).
Future<T> call<T>(String method, [Object? params]) => Isolate.run(
  () => _Lib.instance.exchange(_Lib.instance.call, {'method': method, 'params': ?params}) as T,
);

/// Ends every session (each with a goodbye) and drops the core's state.
Future<void> stop() => Isolate.run(() => _Lib.instance.stop());

/// A controller session's media: the core's packets for this viewer, read
/// on an isolate of its own, and the viewer's control messages to the host.
class Media {
  Media(this.session);

  final int session;
  final _packets = StreamController<Uint8List>();
  Isolate? _reader;
  ReceivePort? _port;
  Pointer<Uint8> _out = nullptr;
  int _outCap = 0;

  /// The packets, first byte their kind; done when the session's media ended.
  Stream<Uint8List> get packets => _packets.stream;

  /// Starts reading.
  Future<void> open() async {
    final port = ReceivePort();
    _port = port;
    port.listen((m) {
      if (m is TransferableTypedData) {
        _packets.add(m.materialize().asUint8List());
      } else {
        port.close();
        _packets.close();
      }
    });
    _reader = await Isolate.spawn(_read, (session, port.sendPort));
  }

  static void _read((int, SendPort) args) {
    final (session, port) = args;
    final lib = _Lib.instance;
    // A frame of a 4K screen fits; the core drops a larger one (-3).
    const cap = 16 << 20;
    final buf = malloc<Uint8>(cap);
    try {
      while (true) {
        final n = lib.mediaRead(session, buf, cap, 250);
        if (n == -2) break;
        if (n < 0) continue;
        port.send(TransferableTypedData.fromList([Uint8List.fromList(buf.asTypedList(n))]));
      }
    } finally {
      malloc.free(buf);
      port.send(null);
    }
  }

  /// Sends one control message (`{"type": …}`) to the host.
  /// Returns: 0, -1 malformed, -2 ended, -3 refused as behind.
  int send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    final n = body.length + 1;
    if (n > _outCap) {
      if (_out != nullptr) malloc.free(_out);
      _outCap = n < 4096 ? 4096 : n;
      _out = malloc<Uint8>(_outCap);
    }
    final view = _out.asTypedList(n);
    view[0] = Packet.control;
    view.setAll(1, body);
    return _Lib.instance.mediaWrite(session, _out, n);
  }

  /// Sends one input event (`{kind, …}`).
  int input(Map<String, Object?> event) => send({'type': 'input', 'event': event});

  /// Sends tunnel bytes (`[14]` + bytes); blocks until the core has room,
  /// so callers run it off the UI isolate ([writeTunnel]).
  static int writeRaw(int session, Uint8List packet) {
    final p = malloc<Uint8>(packet.length);
    try {
      p.asTypedList(packet.length).setAll(0, packet);
      return _Lib.instance.mediaWrite(session, p, packet.length);
    } finally {
      malloc.free(p);
    }
  }

  /// Stops listening. The reader ends by itself once the session closes
  /// (`session.close` makes the read answer -2); it is killed only if it
  /// is still there a few seconds later.
  void close() {
    final reader = _reader;
    _reader = null;
    if (reader != null) Timer(const Duration(seconds: 3), () => reader.kill(priority: Isolate.immediate));
    _port?.close();
    if (!_packets.isClosed) _packets.close();
    if (_out != nullptr) malloc.free(_out);
    _out = nullptr;
    _outCap = 0;
  }
}

