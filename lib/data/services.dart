// A device's own services through Kyokai tunnels: an SSH shell, its Remote
// Desktop, its VNC server (doc/dev/api-services.md), each a client of
// libkyokai_clients.so that this session drives and reads.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../core/clients.dart';
import '../core/native.dart';
import 'log.dart';

enum ServiceKind {
  ssh,
  rdp,
  vnc;

  /// The sign-in methods it offers, the first the default
  /// (internal/gui/servicetab.go signInMethods).
  List<String> get methods => switch (this) {
    ssh => const ['key', 'password'],
    rdp => const ['account', 'none'],
    vnc => const ['password', 'account', 'none'],
  };
}

/// What a sign-in form gives an open: the method chosen, and what it needs.
class ServiceSignIn {
  const ServiceSignIn({required this.method, this.user = '', this.domain = '', this.password = '', this.remember = true});
  final String method;
  final String user;
  final String domain;
  final String password;
  final bool remember;
}

class ServiceSession extends ChangeNotifier {
  ServiceSession(this.deviceId, this.kind, this.title, {this.address});

  final String deviceId;
  final ServiceKind kind;
  final String title;
  final String? address;

  int? id;

  /// connecting, connected, failed or closed.
  String state = 'connecting';

  /// Why it failed or ended (cmd/kyokai-clients reason): a tunnel failure
  /// or refusal, need-sign-in, sign-in-required, sign-in-failed, no-answer,
  /// no-secure-sign-in, host-key-changed, ended, replaced, unreadable.
  String? error;

  /// SSH: the server key it offered after its key changed.
  String? hostKey;

  ClientStream? _stream;

  // ---- SSH
  late final terminal = Terminal(
    maxLines: 10000,
    onOutput: (data) => write(data),
    onResize: (w, h, _, _) => _resize(w, h),
  );
  late final _text = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_TerminalSink(terminal));
  int _cols = 80, _rows = 24;

  // ---- Remote Desktop and VNC: the picture, patched by frames.
  Uint8List? _rgba;
  int width = 0, height = 0;
  ui.Image? picture;
  bool _decoding = false, _again = false;

  /// Text the host copied, not yet taken to the phone's clipboard.
  String? hostClipboard;

  bool get connected => state == 'connected';
  bool get ended => state == 'failed' || state == 'closed';

  /// Opens it, with [signIn] from the form, or null for the sign-in saved.
  /// [trust], SSH: the server key line the person chose to trust.
  Future<void> open({ServiceSignIn? signIn, String? trust, String locale = 'en', int width = 0, int height = 0}) async {
    await _stop();
    state = 'connecting';
    error = null;
    hostKey = null;
    notifyListeners();
    try {
      final r = clientsCall('${kind.name}.open', {
        'device_id': deviceId,
        'address': ?address,
        if (signIn != null) ...{
          'method': signIn.method,
          'user': signIn.user,
          'domain': signIn.domain,
          'password': signIn.password,
          'remember': signIn.remember,
        },
        'trust': ?trust,
        'cols': _cols,
        'rows': _rows,
        'locale': locale,
        'width': width,
        'height': height,
      });
      final id = (r['id'] as num).toInt();
      this.id = id;
      final stream = ClientStream(id);
      _stream = stream;
      stream.packets.listen(_onPacket);
      await stream.open();
      Log.info('service', '${kind.name} $id to ${deviceId.substring(0, 3)}…');
    } catch (e) {
      state = 'failed';
      error = '$e';
      Log.error('service', e);
      notifyListeners();
    }
  }

  /// Takes a packet as if the client sent it.
  @visibleForTesting
  void packetForTest(Uint8List p) => _onPacket(p);

  /// The picture's pixels, RGBA.
  @visibleForTesting
  Uint8List? get pixels => _rgba;

  void _onPacket(Uint8List p) {
    if (p.isEmpty) return;
    final body = Uint8List.sublistView(p, 1);
    switch (p[0]) {
      case ClientPacket.state:
        final s = (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
        state = '${s['state']}';
        error = s['error'] as String?;
        hostKey = s['host_key'] as String?;
        Log.info('service', '${kind.name} $id: $state${error == null ? '' : ' ($error)'}');
        if (state == 'connected' && kind == ServiceKind.ssh) _resize(_cols, _rows);
        notifyListeners();
      case ClientPacket.data:
        _text.add(body);
      case ClientPacket.frame:
        _frame(body);
      case ClientPacket.clipboard:
        hostClipboard = utf8.decode(body, allowMalformed: true);
        unawaited(Native.setClipboardText(hostClipboard!));
        notifyListeners();
    }
  }

  void _frame(Uint8List b) {
    if (b.length < 24) return;
    final h = ByteData.sublistView(b, 0, 24);
    final x = h.getUint32(0), y = h.getUint32(4), w = h.getUint32(8), rows = h.getUint32(12);
    final pw = h.getUint32(16), ph = h.getUint32(20);
    if (pw != width || ph != height || _rgba == null) {
      width = pw;
      height = ph;
      _rgba = Uint8List(pw * ph * 4);
    }
    final rgba = _rgba!;
    final px = Uint8List.sublistView(b, 24);
    final row = w * 4;
    for (var r = 0; r < rows && (r + 1) * row <= px.length; r++) {
      final at = ((y + r) * pw + x) * 4;
      if (at + row > rgba.length) break;
      rgba.setRange(at, at + row, px, r * row);
    }
    _decode();
  }

  /// Makes the picture from the pixels, one at a time: a frame that comes
  /// meanwhile makes the next.
  void _decode() {
    if (_decoding) {
      _again = true;
      return;
    }
    final rgba = _rgba;
    if (rgba == null || width == 0) return;
    _decoding = true;
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, (img) {
      picture?.dispose();
      picture = img;
      _decoding = false;
      notifyListeners();
      if (_again) {
        _again = false;
        _decode();
      }
    });
  }

  void _call(String method, [Map<String, Object?> params = const {}]) {
    final id = this.id;
    if (id == null || ended) return;
    try {
      clientsCall(method, {'id': id, ...params});
    } catch (e) {
      Log.error('service', e);
    }
  }

  // ---- SSH input

  /// Ctrl or Alt tapped on the extra keys row: they hold for the next key.
  bool ctrl = false, alt = false;

  void write(String data) {
    if (!connected) return;
    if ((ctrl || alt) && data.length == 1) {
      var c = data.codeUnitAt(0);
      if (ctrl && c >= 0x40 && c < 0x80) c &= 0x1f;
      data = '${alt ? '\x1b' : ''}${String.fromCharCode(c)}';
      ctrl = alt = false;
      notifyListeners();
    }
    _call('write', {'data': base64Encode(utf8.encode(data))});
  }

  void _resize(int cols, int rows) {
    _cols = cols;
    _rows = rows;
    if (connected) _call('resize', {'cols': cols, 'rows': rows});
  }

  // ---- Remote Desktop and VNC input, in the picture's pixels
  void pointer(int x, int y, int buttons) => _call('pointer', {'x': x, 'y': y, 'buttons': buttons});
  void scroll(int x, int y, double dx, double dy) => _call('scroll', {'x': x, 'y': y, 'dx': dx, 'dy': dy});
  void scancode(int code, bool down) => _call('scancode', {'code': code, 'down': down});
  void key(int keysym, bool down) => _call('key', {'keysym': keysym, 'down': down});
  void text(String s) => _call('text', {'text': s});
  void clipboard(String s) => _call('clipboard', {'text': s});

  Future<void> _stop() async {
    _call('close');
    _stream?.close();
    _stream = null;
  }

  Future<void> close() async {
    await _stop();
    state = 'closed';
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_stop());
    picture?.dispose();
    super.dispose();
  }
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}
