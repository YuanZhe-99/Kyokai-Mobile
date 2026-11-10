// Controller sessions: dialing, signing in, and once connected the media
// channel — video into a MediaCodec texture, sound, the host's cursor,
// displays, clipboard, session actions and the host's AI task — and the
// input and settings this side sends back (third_party/kyokai core
// session.rs, media.rs; the desktop GUI's viewer.go does the same).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/ffi.dart' as core;
import '../core/native.dart';
import 'engine.dart';
import 'log.dart';
import 'model.dart';

/// What a desktop session asks for (the desktop GUI's `desktopWant`).
const desktopWant = ['view-screen', 'control-input', 'clipboard', 'hear-sound'];

/// What an AI link asks for: no picture, the host's AI.
const aiWant = ['run-ai-task', 'approve-ai-action'];

enum SessionKind { desktop, ai }

/// The viewer's picture settings (`quality`, `codec`).
class Quality {
  const Quality({this.preset = 'balanced', this.fps = 60, this.size = 'auto', this.codec = 'auto'});
  final String preset;
  final int fps;
  final String size;
  final String codec;

  Quality copyWith({String? preset, int? fps, String? size, String? codec}) => Quality(
    preset: preset ?? this.preset,
    fps: fps ?? this.fps,
    size: size ?? this.size,
    codec: codec ?? this.codec,
  );
}

class Sessions extends ChangeNotifier with WidgetsBindingObserver {
  /// Decoders opened from now on draw into a SurfaceView (Prefs.videoView).
  bool videoView = true;

  Sessions(this.engine) {
    engine.addListener(_onStatus);
    WidgetsBinding.instance.addObserver(this);
    Native.keyFrames.stream.listen((texture) {
      for (final s in open) {
        if (s.texture?.id == texture) s.requestKeyFrame();
      }
    });
    _clipTimer = Timer.periodic(const Duration(seconds: 2), (_) => _offerClipboard());
  }

  final Engine engine;
  final List<RemoteSession> open = [];
  Timer? _clipTimer;
  String? _lastClip;
  bool _front = true;
  String _notice = '';

  RemoteSession? find(String deviceId, SessionKind kind) =>
      open.where((s) => s.deviceId == deviceId && s.kind == kind && !s.ended).firstOrNull;

  /// Opens (or returns the open) session to a host.
  Future<RemoteSession> connect(
    String deviceId, {
    SessionKind kind = SessionKind.desktop,
    String password = '',
    String? address,
    bool remember = false,
    String? route,
  }) async {
    final existing = find(deviceId, kind);
    if (existing != null && password.isEmpty) return existing;
    if (existing != null) await existing.close();
    final s = RemoteSession._(this, deviceId, kind, address: address, route: route);
    open.add(s);
    notifyListeners();
    await s._dial(password, remember);
    return s;
  }

  Future<void> closeAll() async {
    for (final s in [...open]) {
      await s.close();
    }
  }

  void _remove(RemoteSession s) {
    open.remove(s);
    notifyListeners();
    _updateNotice();
  }

  void _onStatus() {
    for (final s in [...open]) {
      s._onStatus(engine.status);
    }
    _updateNotice();
  }

  void _updateNotice() {
    final live = open.where((s) => s.state == 'connected' || s.state == 'reconnecting').toList();
    final text = live.isEmpty ? '' : live.map((s) => s.title).toSet().join(', ');
    if (text == _notice) return;
    _notice = text;
    unawaited(Native.sessionsNotice(text.isEmpty ? null : text).catchError((Object e) => Log.error('notice', e)));
    unawaited(Native.keepScreenOn(live.any((s) => s.kind == SessionKind.desktop)));
  }

  /// Offers what was copied on the phone to hosts that share the clipboard
  /// (Android lets the app read it only while in front).
  Future<void> _offerClipboard() async {
    if (!_front || !open.any((s) => s.connected && s.granted.contains('clipboard'))) return;
    try {
      final text = await Native.clipboardText();
      if (text == null || text.isEmpty || text == _lastClip) return;
      _lastClip = text;
      await engine.call<Object?>('android.clipboard', {'text': text});
    } catch (e) {
      Log.error('clipboard', e);
    }
  }

  /// Text the host copied: put on the phone's clipboard, not offered back.
  Future<void> _fromHost(String text) async {
    _lastClip = text;
    await Native.setClipboardText(text);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _front = state == AppLifecycleState.resumed;
    for (final s in open) {
      s._clipboardUse();
    }
    if (_front) unawaited(_offerClipboard());
  }

  @override
  void dispose() {
    _clipTimer?.cancel();
    engine.removeListener(_onStatus);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class RemoteSession extends ChangeNotifier {
  RemoteSession._(this._owner, this.deviceId, this.kind, {this.address, this.route});

  /// A session that dials nothing, for widget tests.
  @visibleForTesting
  RemoteSession.forTest(Sessions owner, String deviceId) : this._(owner, deviceId, SessionKind.desktop);

  final Sessions _owner;
  final String deviceId;
  final SessionKind kind;
  final String? address;
  final String? route;

  int? id;
  String state = 'connecting';
  String? failure;
  String? dialError;
  List<String> granted = const [];
  About peer = About(const {});
  bool ended = false;

  core.Media? _media;
  StreamSubscription<Uint8List>? _packets;

  // ---- Picture
  String? _videoStart;
  Json videoStart = const {};
  VideoTexture? texture;
  bool unsupported = false;
  ui.Image? rawImage;
  Size pictureSize = Size.zero;
  bool _opening = false;
  bool _waitKey = true;
  DateTime _lastKeyAsk = DateTime(0);
  DateTime lastFrame = DateTime(0);
  int framesShown = 0;

  // ---- What the host tells
  Json stats = const {};
  Offset? cursor;
  bool cursorVisible = false;
  List<Json> displays = const [];
  int display = 0;
  Json actions = const {};
  List<String> codecs = const [];
  bool inputPaused = false;

  // ---- The host's AI
  Json? aiTask;
  String? aiError;
  String aiDraft = '';
  final aiExports = StreamController<Json>.broadcast();

  // ---- This side's choices
  Quality quality = const Quality();
  bool sound = true;
  bool shareClipboard = true;

  Engine get _engine => _owner.engine;
  bool get connected => state == 'connected';
  bool get confirming => state == 'confirming';
  String get title => peer.name.isNotEmpty ? peer.name : (_engine.status.host(deviceId)?.title ?? formatId(deviceId));
  bool get mayControl => granted.contains('control-input');
  bool get mayRunAi => granted.contains('run-ai-task');
  bool get mayApprove => granted.contains('approve-ai-action');

  /// Whether this session asked the engine to poll quickly; each session
  /// asks at most once, so ending twice cannot slow another session down.
  bool _hurrying = false;
  void _hurry(bool on) {
    if (_hurrying == on) return;
    _hurrying = on;
    _engine.hurry(on);
  }

  Future<void> _dial(String password, bool remember) async {
    dialError = null;
    failure = null;
    state = 'connecting';
    notifyListeners();
    _hurry(true);
    try {
      final r = await _engine.act<Map<String, Object?>>('session.connect', {
        'device_id': deviceId,
        'password': password,
        'want': kind == SessionKind.ai ? aiWant : desktopWant,
        'remember': remember,
        'address': ?address,
        'route': ?route,
      });
      id = (r['id'] as num).toInt();
      Log.info('session', 'dialing ${formatId(deviceId)} as $id (${kind.name})');
    } catch (e) {
      dialError = '$e';
      state = 'failed';
      _hurry(false);
      notifyListeners();
    }
  }

  /// Signs in again with a typed password (the host asked, or refused).
  Future<void> retry(String password, {bool remember = false}) async {
    final old = id;
    _stopMedia();
    if (old != null) {
      try {
        await _engine.call<Object?>('session.close', {'id': old});
      } catch (_) {}
    }
    id = null;
    _videoStart = null;
    await _dial(password, remember);
  }

  void _onStatus(Status status) {
    final id = this.id;
    if (id == null || ended) return;
    final info = status.session(id);
    if (info == null) return;
    final was = state;
    state = info.state;
    failure = info.failureCode;
    granted = info.granted;
    if (info.peer.name.isNotEmpty || info.peer.os.isNotEmpty) peer = info.peer;
    if (state == was) return;
    Log.info('session', '$id: $was -> $state${failure == null ? '' : ' ($failure)'}');
    if ((state == 'connected' || state == 'reconnecting') && _media == null) _startMedia();
    if (info.ended) {
      _stopMedia();
      _hurry(false);
    }
    notifyListeners();
  }

  // ---- Media ------------------------------------------------------------

  void _startMedia() {
    final media = core.Media(id!);
    _media = media;
    unawaited(media.open());
    _packets = media.packets.listen(_onPacket, onDone: () => Log.info('session', '$id: media ended'));
    send({'type': 'key-frame'});
    if (kind == SessionKind.desktop) {
      _sendQuality();
      if (quality.codec != 'auto') send({'type': 'codec', 'codec': quality.codec});
      send({'type': 'audio', 'on': sound});
      _clipboardUse();
      unawaited(Native.soundOn(sound));
    }
  }

  void _stopMedia() {
    _packets?.cancel();
    _packets = null;
    _media?.close();
    _media = null;
    final t = texture;
    texture = null;
    if (t != null) unawaited(Native.closeVideo(t.id));
    if (kind == SessionKind.desktop && !_owner.open.any((s) => s != this && s.connected && s.sound)) {
      unawaited(Native.soundOn(false));
    }
  }

  /// Sends a control message; -3 (behind) is dropped as the desktop does.
  int send(Json message) => _media?.send(message) ?? -2;

  /// Takes one of the core's packets as if it came from the media reader.
  @visibleForTesting
  void packetForTest(Uint8List p) => _onPacket(p);

  void _onPacket(Uint8List p) {
    if (p.isEmpty) return;
    final kind = p[0];
    final body = Uint8List.sublistView(p, 1);
    Json json() {
      try {
        return (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
      } catch (_) {
        return const {};
      }
    }

    switch (kind) {
      case core.Packet.videoStart:
        final text = utf8.decode(body);
        // The host sends the same start again with every key frame asked
        // for: only a change reopens the decoder.
        if (text == _videoStart) return;
        _videoStart = text;
        videoStart = json();
        unawaited(_openVideo());
      case core.Packet.frame:
        _onFrame(body);
      case core.Packet.stats:
        stats = json();
        notifyListeners();
      case core.Packet.cursor:
        final c = json();
        cursor = Offset((c['x'] as num?)?.toDouble() ?? 0, (c['y'] as num?)?.toDouble() ?? 0);
        cursorVisible = c['visible'] == true;
        notifyListeners();
      case core.Packet.displays:
        final d = json();
        displays = ((d['list'] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();
        display = (d['current'] as num?)?.toInt() ?? 0;
        notifyListeners();
      case core.Packet.actions:
        actions = json();
        notifyListeners();
      case core.Packet.codecs:
        codecs = ((json()['codecs'] as List?) ?? const []).map((e) => '$e').toList();
        notifyListeners();
      case core.Packet.audio:
        if (sound) Native.feedSound(Uint8List.fromList(body));
      case core.Packet.clipboard:
        final c = json();
        if (c['from'] == 'host' && c['text'] is String && shareClipboard) unawaited(_owner._fromHost(c['text'] as String));
      case core.Packet.input:
        inputPaused = json()['paused'] == true;
        notifyListeners();
      case core.Packet.aiTask:
        aiTask = json();
        aiError = null;
        notifyListeners();
      case core.Packet.aiError:
        aiError = '${json()['error']}';
        notifyListeners();
      case core.Packet.aiDraft:
        aiDraft = '${json()['text'] ?? ''}';
        notifyListeners();
      case core.Packet.aiExport:
        aiExports.add(json());
    }
  }

  Future<void> _openVideo() async {
    final start = videoStart;
    final codec = '${start['codec']}';
    final w = (start['width'] as num?)?.toInt() ?? 0;
    final h = (start['height'] as num?)?.toInt() ?? 0;
    pictureSize = Size(w.toDouble(), h.toDouble());
    final old = texture;
    texture = null;
    rawImage = null;
    unsupported = false;
    _waitKey = true;
    if (old != null) await Native.closeVideo(old.id);
    notifyListeners();
    if (codec == 'raw-rgba') return; // Drawn from the frames themselves.
    _opening = true;
    try {
      final t = await Native.openVideo(codec, w, h, view: _owner.videoView);
      if (_videoStart == null || !identical(start, videoStart)) {
        if (t != null) await Native.closeVideo(t.id);
        return;
      }
      texture = t;
      unsupported = t == null;
      Log.info('video', '$id: $codec ${w}x$h -> ${t?.decoder ?? 'no decoder'}');
      if (t == null) {
        send({'type': 'no-picture', 'for_ms': 0, 'why': 'decode-error'});
      } else {
        requestKeyFrame(force: true);
      }
    } catch (e) {
      Log.error('video', e);
      unsupported = true;
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  void _onFrame(Uint8List body) {
    if (body.length < 9) return;
    final key = body[0] & 1 == 1;
    final codec = videoStart['codec'];
    if (codec == 'raw-rgba') {
      _rawFrame(Uint8List.sublistView(body, 9));
      return;
    }
    final t = texture;
    if (t == null || _opening) return;
    if (_waitKey && !key) {
      requestKeyFrame();
      return;
    }
    _waitKey = false;
    final pts = ByteData.sublistView(body, 1, 9).getUint64(0);
    final frame = Uint8List.sublistView(body, 9);
    final first = framesShown == 0;
    framesShown++;
    lastFrame = DateTime.now();
    if (first) notifyListeners();
    unawaited(
      Native.feed(t.id, frame, key: key, ptsUs: pts).then((wantKey) {
        if (wantKey) requestKeyFrame();
      }).catchError((Object e) => Log.error('feed', e)),
    );
  }

  Future<void> _rawFrame(Uint8List rgba) async {
    final w = pictureSize.width.toInt();
    final h = pictureSize.height.toInt();
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return;
    final copy = Uint8List.fromList(rgba);
    ui.decodeImageFromPixels(copy, w, h, ui.PixelFormat.rgba8888, (img) {
      rawImage?.dispose();
      rawImage = img;
      lastFrame = DateTime.now();
      notifyListeners();
    });
  }

  /// Asks the host for a key frame, at most twice a second.
  void requestKeyFrame({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastKeyAsk) < const Duration(milliseconds: 500)) return;
    _lastKeyAsk = now;
    _waitKey = true;
    send({'type': 'key-frame'});
  }

  // ---- Settings sent to the host ------------------------------------------

  void _sendQuality() => send({
    'type': 'quality',
    'preset': quality.preset,
    'fps': quality.fps,
    'i444': false,
    'size': quality.size,
  });

  void setQuality(Quality q) {
    final codecChanged = q.codec != quality.codec;
    quality = q;
    _sendQuality();
    if (codecChanged) send({'type': 'codec', 'codec': q.codec});
    notifyListeners();
  }

  void setSound(bool on) {
    sound = on;
    send({'type': 'audio', 'on': on});
    unawaited(Native.soundOn(on));
    notifyListeners();
  }

  void setShareClipboard(bool on) {
    shareClipboard = on;
    _clipboardUse();
    notifyListeners();
  }

  void _clipboardUse() {
    if (_media == null) return;
    send({'type': 'clipboard-use', 'share': shareClipboard, 'front': _owner._front});
  }

  void showDisplay(int index) {
    send({'type': 'display', 'index': index});
    display = index;
    notifyListeners();
  }

  /// A session action: `lock`, `ctrl-alt-del`, `block`, `unblock`,
  /// `privacy-on`, `privacy-off`, `wake`.
  void action(String name) => send({'type': 'action', 'action': name});

  // ---- Input ---------------------------------------------------------------

  void input(Json event) {
    final m = _media;
    if (m == null || !mayControl) return;
    m.input(event);
  }

  void pointer(String action, double x, double y, {int button = 0}) =>
      input({'kind': 'pointer', 'action': action, 'button': button, 'x': x, 'y': y});

  void scroll(double dx, double dy) => input({'kind': 'scroll', 'dx': dx, 'dy': dy});

  void scan(int code, bool down, {bool caps = false}) =>
      input({'kind': 'scan', 'code': code, 'down': down, 'caps': caps, 'num': true});

  /// Text as it is (pasted, or from the system keyboard), in 4 KB pieces.
  void text(String s) {
    // In pieces of at most 4000 UTF-8 bytes, never splitting a character.
    final piece = StringBuffer();
    var size = 0;
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      final n = utf8.encode(ch).length;
      if (size + n > 4000) {
        input({'kind': 'text', 'text': piece.toString()});
        piece.clear();
        size = 0;
      }
      piece.write(ch);
      size += n;
    }
    if (piece.isNotEmpty) input({'kind': 'text', 'text': piece.toString()});
  }

  // ---- The host's AI -------------------------------------------------------

  void aiStart(String instruction, {String? thinking}) => send({
    'type': 'ai-start',
    'key': DateTime.now().microsecondsSinceEpoch.toRadixString(36),
    'instruction': instruction,
    'thinking': ?thinking,
  });

  void aiCommand(String command, {String? text}) {
    final task = aiTask;
    if (task == null) return;
    send({'type': 'ai-command', 'id': task['id'], 'command': command, 'text': ?text});
  }

  void aiDecide(bool approve) {
    final task = aiTask;
    if (task == null) return;
    send({'type': 'ai-decide', 'id': task['id'], 'approve': approve});
  }

  void setAiDraft(String text) => send({'type': 'ai-draft', 'text': text});

  Future<void> close() async {
    if (ended) return;
    ended = true;
    _stopMedia();
    final id = this.id;
    if (id != null) {
      try {
        await _engine.call<Object?>('session.close', {'id': id});
      } catch (e) {
        Log.error('session', e);
      }
    }
    _hurry(false);
    _owner._remove(this);
    aiExports.close();
    rawImage?.dispose();
    notifyListeners();
  }
}
