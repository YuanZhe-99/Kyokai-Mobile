// The app's Kotlin side (MainActivity.kt): what the core leaves to Android.
// Video and sound decode through MediaCodec, the secrets store's key lives
// under the Android Keystore, a foreground service keeps sessions alive.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/log.dart';

abstract final class Native {
  static const _m = MethodChannel('kyokai/native');
  static const _video = BasicMessageChannel<ByteData?>('kyokai/video', BinaryCodec());
  static const _sound = BasicMessageChannel<ByteData?>('kyokai/sound', BinaryCodec());
  static const _events = MethodChannel('kyokai/events');

  /// Texture ids whose decoder asked for a key frame.
  static final keyFrames = StreamController<int>.broadcast();

  static void listen() {
    _events.setMethodCallHandler((call) async {
      if (call.method == 'keyFrame') keyFrames.add((call.arguments as num).toInt());
      if (call.method == 'log') Log.info('native', '${call.arguments}');
      if (call.method == 'hinge') hingeAngle.value = (call.arguments as num).toDouble();
    });
  }

  /// A foldable's hinge angle (0 closed, 180 flat) while someone watches it;
  /// null before the first reading or without a sensor.
  static final hingeAngle = ValueNotifier<double?>(null);
  static int _hingeWatchers = 0;

  /// Whether the device has a hinge sensor (null until asked).
  static bool? hingeSensor;

  /// Starts or stops (counted) the hinge angle's readings.
  static Future<void> watchHinge(bool on) async {
    _hingeWatchers = (_hingeWatchers + (on ? 1 : -1)).clamp(0, 1 << 20);
    if (on && _hingeWatchers != 1 || !on && _hingeWatchers != 0) return;
    try {
      hingeSensor = await _m.invokeMethod<bool>('hinge', {'on': on});
    } catch (_) {}
  }

  /// The secrets store's key, base64; null when the Keystore cannot keep it.
  static Future<String?> masterKey() => _m.invokeMethod<String>('masterKey');

  /// The codecs this device decodes in hardware or software:
  /// `[{codec, name, hardware, max_width, max_height}]`.
  static Future<List<Map<String, Object?>>> decoders() async =>
      ((await _m.invokeListMethod<Object?>('decoders')) ?? const [])
          .map((e) => (e as Map).cast<String, Object?>())
          .toList();

  /// Opens a decoder drawing into a new Flutter texture, or with [view]
  /// into the SurfaceView the page embeds for it.
  static Future<VideoTexture?> openVideo(String codec, int width, int height, {bool view = false}) async {
    final r = await _m.invokeMapMethod<String, Object?>('videoOpen', {
      'codec': codec,
      'width': width,
      'height': height,
      'view': view,
    });
    if (r == null) return null;
    return VideoTexture((r['texture'] as num).toInt(), '${r['decoder']}', r['hardware'] == true, view: r['view'] == true);
  }

  /// The decoder in use and its counts: fed, decoded, errors, last error.
  static Future<Map<String, Object?>?> videoInfo(int texture) =>
      _m.invokeMapMethod<String, Object?>('videoInfo', {'texture': texture});

  static Future<void> closeVideo(int texture) => _m.invokeMethod('videoClose', {'texture': texture});

  /// Feeds one frame; true when the decoder failed and wants a key frame.
  static Future<bool> feed(int texture, Uint8List frame, {required bool key, required int ptsUs}) async {
    final b = ByteData(17 + frame.length);
    b.setInt64(0, texture);
    b.setUint8(8, key ? 1 : 0);
    b.setUint64(9, ptsUs);
    b.buffer.asUint8List(17).setAll(0, frame);
    final r = await _video.send(b);
    return r != null && r.lengthInBytes > 0 && r.getUint8(0) == 1;
  }

  static Future<bool> soundOn(bool on) async => (await _m.invokeMethod<bool>('sound', {'on': on})) ?? false;

  /// One Opus packet of the host's sound.
  static void feedSound(Uint8List packet) => _sound.send(ByteData.sublistView(packet));

  static Future<void> keepScreenOn(bool on) => _m.invokeMethod('keepOn', {'on': on});

  /// Starts, updates or (null) stops the foreground service that keeps
  /// sessions alive in the background.
  static Future<void> sessionsNotice(String? text) => _m.invokeMethod('sessions', {'text': text});

  /// The device's clipboard text, and setting it.
  static Future<String?> clipboardText() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  static Future<void> setClipboardText(String text) => Clipboard.setData(ClipboardData(text: text));

  /// The clipboard's image (Clip.kt): its mark, and its PNG unless the
  /// mark is [unless] (the copy already read). Null without an image.
  static Future<({String mark, Uint8List? png})?> clipboardImage({String? unless}) async {
    final r = await _m.invokeMapMethod<String, Object?>('clipImage', {'unless': unless});
    if (r == null) return null;
    return (mark: '${r['mark']}', png: r['png'] as Uint8List?);
  }

  /// Puts a PNG on the clipboard. Returns the mark [clipboardImage] reads it with.
  static Future<String?> setClipboardImage(Uint8List png) => _m.invokeMethod<String>('setClipImage', {'png': png});

  /// Build facts for the diagnostics page: Android version, model, ABI.
  static Future<Map<String, Object?>> device() async =>
      (await _m.invokeMapMethod<String, Object?>('device')) ?? const {};
}

class VideoTexture {
  VideoTexture(this.id, this.decoder, this.hardware, {this.view = false});
  final int id;

  /// It draws into a SurfaceView (`kyokai/video-view`), not a texture.
  final bool view;
  final String decoder;
  final bool hardware;
}
