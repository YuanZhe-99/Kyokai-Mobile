// Kyokai's SSH, Remote Desktop and VNC clients (libkyokai_clients.so, Go,
// third_party/kyokai cmd/kyokai-clients): a JSON call and, per client, a
// stream of packets read on an isolate of its own, like the core's media.
// The library uses this app's core, whose exports it is given here.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The library's interface version this app speaks.
const clientsAbi = 1;

/// Packet kinds of a client, byte 0 of each (cmd/kyokai-clients/packets.go).
abstract final class ClientPacket {
  /// JSON {state, error?, host_key?, width?, height?}.
  static const state = 1;

  /// What an SSH shell wrote.
  static const data = 2;

  /// x, y, width, height, picture width, picture height (u32 BE), then RGBA.
  static const frame = 3;

  /// Text the host copied.
  static const clipboard = 4;
}

typedef _ExchangeC = Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _Exchange = int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

final class _Lib {
  _Lib._(DynamicLibrary l)
    : abi = l.lookupFunction<Uint32 Function(), int Function()>('kyokai_clients_abi'),
      init = l
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
            void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
          >('kyokai_clients_init'),
      call = l.lookupFunction<_ExchangeC, _Exchange>('kyokai_clients_call'),
      free = l.lookupFunction<Void Function(Pointer<Uint8>, Size), void Function(Pointer<Uint8>, int)>(
        'kyokai_clients_free',
      ),
      read = l
          .lookupFunction<Int64 Function(Uint64, Pointer<Uint8>, Size, Uint32), int Function(int, Pointer<Uint8>, int, int)>(
            'kyokai_clients_read',
          );

  static final instance = _Lib._(DynamicLibrary.open('libkyokai_clients.so'));

  final int Function() abi;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>) init;
  final _Exchange call;
  final void Function(Pointer<Uint8>, int) free;
  final int Function(int, Pointer<Uint8>, int, int) read;
}

class ClientsError implements Exception {
  ClientsError(this.message);
  final String message;
  @override
  String toString() => message;
}

bool _ready = false;

/// Loads the library and gives it the core's exports (once).
void _ensure() {
  if (_ready) return;
  final lib = _Lib.instance;
  if (lib.abi() != clientsAbi) throw ClientsError('clients ABI ${lib.abi()}, this app speaks $clientsAbi');
  final core = DynamicLibrary.open('libkyokai_core.so');
  lib.init(
    core.lookup<Void>('kyokai_call'),
    core.lookup<Void>('kyokai_free'),
    core.lookup<Void>('kyokai_media_read'),
    core.lookup<Void>('kyokai_media_write'),
  );
  _ready = true;
}

/// Calls one of the library's methods; quick, so on the calling isolate.
Map<String, Object?> clientsCall(String method, Map<String, Object?> params) {
  _ensure();
  final lib = _Lib.instance;
  final body = utf8.encode(jsonEncode({'method': method, 'params': params}));
  final input = malloc<Uint8>(body.length);
  final out = malloc<Pointer<Uint8>>();
  final outLen = malloc<Size>();
  try {
    input.asTypedList(body.length).setAll(0, body);
    if (lib.call(input, body.length, out, outLen) != 0) throw ClientsError('refused');
    final answer = utf8.decode(out.value.asTypedList(outLen.value));
    lib.free(out.value, outLen.value);
    final doc = jsonDecode(answer) as Map<String, Object?>;
    if (doc['ok'] != true) throw ClientsError('${doc['error']}');
    return (doc['result'] as Map?)?.cast<String, Object?>() ?? const {};
  } finally {
    malloc.free(input);
    malloc.free(out);
    malloc.free(outLen);
  }
}

/// A client's packets, read on an isolate of their own until it ends.
class ClientStream {
  ClientStream(this.id);

  final int id;
  final _packets = StreamController<Uint8List>();
  Isolate? _reader;

  Stream<Uint8List> get packets => _packets.stream;

  Future<void> open() async {
    _ensure();
    final port = ReceivePort();
    port.listen((m) {
      if (m is TransferableTypedData) {
        _packets.add(m.materialize().asUint8List());
      } else {
        port.close();
        _packets.close();
      }
    });
    _reader = await Isolate.spawn(_read, (id, port.sendPort));
  }

  static void _read((int, SendPort) args) {
    final (id, port) = args;
    final lib = _Lib.instance;
    var cap = 4 << 20;
    var buf = malloc<Uint8>(cap);
    try {
      while (true) {
        final n = lib.read(id, buf, cap, 250);
        if (n == -2) break;
        if (n == -1) continue;
        if (n < -3) {
          // A picture bigger than the buffer: grow and read it again.
          malloc.free(buf);
          cap = -n;
          buf = malloc<Uint8>(cap);
          continue;
        }
        if (n <= 0) continue;
        port.send(TransferableTypedData.fromList([Uint8List.fromList(buf.asTypedList(n))]));
      }
    } finally {
      malloc.free(buf);
      port.send(null);
    }
  }

  /// Stops listening; the reader ends once the client has ended.
  void close() {
    final r = _reader;
    _reader = null;
    if (r != null) Timer(const Duration(seconds: 5), () => r.kill(priority: Isolate.immediate));
    if (!_packets.isClosed) _packets.close();
  }
}
