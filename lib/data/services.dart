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

  /// The library's call that opens it.
  @protected
  String get openMethod => '${kind.name}.open';

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
      final r = clientsCall(openMethod, {
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

  /// Remote Desktop: asks the host for a desktop of [width] by [height]
  /// (cmd/kyokai-clients display, RDP SetDisplay); others ignore it.
  void display(int width, int height) {
    final id = this.id;
    if (id == null || !connected || kind != ServiceKind.rdp) return;
    try {
      clientsCall('display', {'id': id, 'width': width, 'height': height, 'scale': 100});
    } catch (e) {
      Log.error('service', e);
    }
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

/// A file or folder on the server, as sftp.list gives it.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    this.dir = false,
    this.size = 0,
    this.mode = '',
    required this.modified,
    this.link = false,
  });

  factory RemoteEntry.fromJson(Map<String, Object?> j) => RemoteEntry(
    name: '${j['name']}',
    dir: j['dir'] == true,
    size: (j['size'] as num?)?.toInt() ?? 0,
    mode: '${j['mode'] ?? ''}',
    modified: DateTime.fromMillisecondsSinceEpoch(((j['modified'] as num?)?.toInt() ?? 0) * 1000),
    link: j['link'] == true,
  );

  final String name;

  /// A folder, or a link to one.
  final bool dir;
  final int size;

  /// The mode as `ls -l` shows it, e.g. -rw-r--r--.
  final String mode;
  final DateTime modified;
  final bool link;
}

/// A file copied to the server (up) or from it, as its packets tell.
class FileTransfer {
  FileTransfer(this.n);
  final int n;
  bool up = false;
  String name = '';

  /// Where it is on the server, and on this phone.
  String remote = '', local = '';
  int done = 0, total = 0;

  /// waiting, running, done, failed or cancelled.
  String state = 'waiting';

  /// Why it failed (cmd/kyokai-clients fileReason).
  String? error;

  bool get active => state == 'waiting' || state == 'running';

  /// Its progress, 0 to 1, or null before its size is known.
  double? get progress => total > 0 ? (done / total).clamp(0, 1).toDouble() : null;
}

/// An SSH server's files over SFTP (sftp.open: the SSH service's sign-in):
/// one folder listed at a time, and the transfers it runs one after
/// another. Errors of its calls are ClientsError with a reason:
/// permission-denied, not-found, exists, is-folder, connection-lost, or the
/// server's text.
class FilesSession extends ServiceSession {
  FilesSession(String deviceId, String title, {super.address})
    : super(deviceId, ServiceKind.ssh, title);

  @override
  String get openMethod => 'sftp.open';

  /// Opens it anew: a new client numbers its transfers from 1 again.
  @override
  Future<void> open({ServiceSignIn? signIn, String? trust, String locale = 'en', int width = 0, int height = 0}) {
    transfers.clear();
    return super.open(signIn: signIn, trust: trust, locale: locale, width: width, height: height);
  }

  /// The folder shown, absolute once listed ("" the home folder).
  String path = '';
  List<RemoteEntry> entries = const [];
  bool loading = false;

  /// Why the folder could not be listed.
  String? listError;

  /// The transfers, newest first.
  final List<FileTransfer> transfers = [];

  /// One of the files calls on this client.
  @protected
  Future<Map<String, Object?>> request(String method, Map<String, Object?> params) =>
      clientsCallAsync(method, {'id': id, ...params});

  @override
  void _resize(int cols, int rows) {}

  @override
  void _onPacket(Uint8List p) {
    if (p.isNotEmpty && p[0] == ClientPacket.transfer) {
      final j = (jsonDecode(utf8.decode(Uint8List.sublistView(p, 1))) as Map).cast<String, Object?>();
      final t = _transfer((j['transfer'] as num).toInt());
      final was = t.state;
      t
        ..done = (j['done'] as num?)?.toInt() ?? t.done
        ..total = (j['total'] as num?)?.toInt() ?? t.total
        ..state = '${j['state']}'
        ..error = j['error'] as String?;
      // An upload that ended in the folder shown shows there.
      if (t.up && was != t.state && !t.active && _parent(t.remote) == path) unawaited(list());
      notifyListeners();
      return;
    }
    final before = state;
    super._onPacket(p);
    if (state == 'connected' && before != 'connected') unawaited(list(path));
  }

  FileTransfer _transfer(int n) {
    for (final t in transfers) {
      if (t.n == n) return t;
    }
    final t = FileTransfer(n);
    transfers.insert(0, t);
    return t;
  }

  /// The path of [name] in the folder shown.
  String child(String name) => path == '/' ? '/$name' : '$path/$name';

  static String _parent(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  /// The folder above the one shown; null at the root.
  String? get parent => path == '/' || path.isEmpty ? null : _parent(path);

  /// Lists [to] (the folder shown when null) and shows it.
  Future<void> list([String? to]) async {
    if (!connected) return;
    loading = true;
    notifyListeners();
    try {
      final r = await request('sftp.list', {'path': to ?? path});
      path = '${r['path']}';
      entries = [for (final e in (r['entries'] as List? ?? const [])) RemoteEntry.fromJson((e as Map).cast())];
      listError = null;
    } catch (e) {
      listError = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Makes a folder [name] in the folder shown.
  Future<void> mkdir(String name) async {
    await request('sftp.mkdir', {'path': child(name)});
    await list();
  }

  /// Names [e] anew in the folder shown.
  Future<void> rename(RemoteEntry e, String name) async {
    await request('sftp.rename', {'from': child(e.name), 'to': child(name)});
    await list();
  }

  /// Removes a file or an empty folder.
  Future<void> remove(RemoteEntry e) async {
    await request('sftp.remove', {'path': child(e.name)});
    await list();
  }

  /// Copies file [e] of the folder shown to [local] on this phone.
  Future<FileTransfer> download(RemoteEntry e, String local) async {
    final remote = child(e.name);
    final r = await request('sftp.download', {'remote': remote, 'local': local});
    final t = _transfer((r['transfer'] as num).toInt())
      ..name = e.name
      ..remote = remote
      ..local = local
      ..total = e.size;
    notifyListeners();
    return t;
  }

  /// Copies the phone's file [local] into the folder shown, as [name] or,
  /// when that is taken, "name (2).ext".
  Future<FileTransfer> upload(String local, String name) async {
    final remote = child(freeName(name));
    final r = await request('sftp.upload', {'local': local, 'remote': remote});
    final t = _transfer((r['transfer'] as num).toInt())
      ..up = true
      ..name = remote.substring(remote.lastIndexOf('/') + 1)
      ..remote = remote
      ..local = local;
    notifyListeners();
    return t;
  }

  /// [name], or "name (n).ext" when the folder shown has it already.
  String freeName(String name) {
    final taken = {for (final e in entries) e.name};
    if (!taken.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final (stem, ext) = dot > 0 ? (name.substring(0, dot), name.substring(dot)) : (name, '');
    for (var n = 2; ; n++) {
      final s = '$stem ($n)$ext';
      if (!taken.contains(s)) return s;
    }
  }

  Future<void> cancel(FileTransfer t) async {
    if (!t.active) return;
    try {
      await request('sftp.cancel', {'transfer': t.n});
    } catch (e) {
      Log.error('files', e);
    }
  }

  /// Forgets the transfers that ended.
  void clearEnded() {
    transfers.removeWhere((t) => !t.active);
    notifyListeners();
  }

  // A call's answer may come after the page closed.
  bool _gone = false;

  @override
  void notifyListeners() {
    if (!_gone) super.notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

/// The services open from this phone, kept while their page is closed so
/// the Sessions page can go back to them (multi-session); one that fails or
/// closes on its own leaves.
class ServiceSessions extends ChangeNotifier {
  final List<ServiceSession> open = [];

  void add(ServiceSession s) {
    if (open.contains(s)) return;
    open.add(s);
    s.addListener(notifyListeners);
    notifyListeners();
  }

  /// Its page closed: kept while it is connected or still connecting.
  Future<void> pageClosed(ServiceSession s) async {
    if (s.ended) await end(s);
  }

  /// Ends one and forgets it.
  Future<void> end(ServiceSession s) async {
    if (!open.remove(s)) return;
    s.removeListener(notifyListeners);
    notifyListeners();
    await s.close();
    s.dispose();
  }

  /// What the foreground notification names.
  List<String> get liveTitles => [for (final s in open) if (s.connected) s.title];
}
