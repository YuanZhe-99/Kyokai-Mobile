import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/core/native.dart';
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/data/sessions.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/keyboard/keyboard.dart';
import 'package:kyokai_mobile/ui/viewer/posture.dart';
import 'package:kyokai_mobile/ui/viewer/surface.dart';
import 'package:kyokai_mobile/ui/viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  packetTests();
  laptopTests();
  laptopSafeAreaTests();
  keyboardOnEntryTests();
  // An unfolded fold, a phone upright and on its side.
  for (final size in const [Size(1000, 760), Size(412, 915), Size(915, 412)]) {
    testWidgets('a connected session shows its picture at $size', (t) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await Prefs.load();
      final state = AppState(prefs: prefs, engine: Engine());
      final s = RemoteSession.forTest(state.sessions, '123456789')
        ..state = 'connected'
        ..granted = const ['view-screen', 'control-input']
        ..videoStart = const {'codec': 'hevc', 'width': 2560, 'height': 1600}
        ..pictureSize = const Size(2560, 1600)
        ..texture = VideoTexture(7, 'c2.test.hevc.decoder', true);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ViewerPage(session: s),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final texture = find.byType(Texture);
      expect(texture, findsOneWidget);
      final box = t.getSize(texture);
      expect(box.width, greaterThan(100), reason: 'the picture is laid out at $box');
      expect(box.height, greaterThan(100), reason: 'the picture is laid out at $box');
      await t.pumpWidget(const SizedBox());
      state.sessions.dispose();
    });
  }
}

Uint8List _packet(int kind, Object body) => Uint8List.fromList([
  kind,
  ...(body is List<int> ? body : utf8.encode(jsonEncode(body))),
]);

void packetTests() {
  testWidgets('packets from a live session reach the picture (fold)', (t) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), (call) async {
      calls.add(call.method);
      if (call.method == 'videoOpen') {
        return {'texture': 7, 'decoder': 'c2.test.hevc', 'hardware': true, 'view': (call.arguments as Map)['view']};
      }
      return null;
    });
    var fed = 0;
    messenger.setMockMessageHandler('kyokai/video', (m) async {
      fed++;
      return ByteData(1);
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), null);
      messenger.setMockMessageHandler('kyokai/video', null);
    });
    SharedPreferences.setMockInitialValues({'overlay': true});
    final prefs = await Prefs.load();
    final state = AppState(prefs: prefs, engine: Engine());
    final s = RemoteSession.forTest(state.sessions, '123456789')
      ..state = 'connected'
      ..granted = const ['view-screen', 'control-input'];
    t.view.physicalSize = const Size(1000, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ViewerPage(session: s),
      ),
    ));
    s.packetForTest(_packet(1, {'codec': 'hevc', 'width': 2560, 'height': 1600, 'encoder': 'mf', 'hardware': true}));
    await t.pump();
    await t.pump();
    s.packetForTest(_packet(7, {'x': 0.5, 'y': 0.5, 'visible': true}));
    s.packetForTest(_packet(4, {'delay_ms': 93, 'fps': 30, 'frames': 2, 'bitrate': 1000000, 'encode_ms': 4}));
    final frame = Uint8List(9 + 16)..[0] = 1;
    frame.setAll(9, [0, 0, 0, 1, 0x40, 1, 0, 0, 0, 1, 0x26, 1, 0xAF, 0, 0, 0]);
    s.packetForTest(Uint8List.fromList([2, ...frame]));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    expect(calls, contains('videoOpen'));
    expect(s.texture?.id, 7);
    expect(fed, 1);
    // The default: the decoder's own SurfaceView, embedded.
    expect(find.byType(PlatformViewLink), findsOneWidget);
    expect(t.getSize(find.byType(PlatformViewLink)).width, greaterThan(100));
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}

void laptopTests() {
  for (final on in [true, false]) {
    testWidgets('a half-open fold ${on ? 'splits at the hinge' : 'keeps its layout'} with laptop mode ${on ? 'on' : 'off'}',
        (t) async {
      SharedPreferences.setMockInitialValues({'laptopMode': on});
      final state = AppState(prefs: await Prefs.load(), engine: Engine());
      final s = RemoteSession.forTest(state.sessions, '123456789')
        ..state = 'connected'
        ..granted = const ['view-screen', 'control-input']
        ..pictureSize = const Size(2560, 1600)
        ..texture = VideoTexture(7, 'c2.test.hevc.decoder', true);
      t.view.physicalSize = const Size(1000, 760);
      t.view.devicePixelRatio = 1;
      t.view.displayFeatures = [
        const DisplayFeature(
          bounds: Rect.fromLTWH(0, 370, 1000, 20),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(t.view.reset);
      await t.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ViewerPage(session: s),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.byType(RemoteKeyboard), on ? findsOneWidget : findsNothing);
      if (on) expect(t.getSize(find.byType(RemoteSurface)).height, 370);
      await t.pumpWidget(const SizedBox());
      state.sessions.dispose();
    });
  }
}

void keyboardOnEntryTests() {
  for (final (size, shown) in [(const Size(412, 915), true), (const Size(1000, 760), false)]) {
    testWidgets('the keyboard ${shown ? 'opens' : 'stays closed'} on entry at $size', (t) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(prefs: await Prefs.load(), engine: Engine());
      final s = RemoteSession.forTest(state.sessions, '123456789')
        ..state = 'connected'
        ..granted = const ['view-screen', 'control-input']
        ..pictureSize = const Size(2560, 1600)
        ..texture = VideoTexture(7, 'c2.test.hevc.decoder', true);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ViewerPage(session: s),
        ),
      ));
      await t.pump();
      await t.pump();
      expect(find.byType(RemoteKeyboard), shown ? findsOneWidget : findsNothing);
      await t.pumpWidget(const SizedBox());
      state.sessions.dispose();
    });
  }

  // A Galaxy Z Fold reports its fold as flat at any angle (seen on an
  // SM-F971U1): the angle says half open, the fold's bounds say which way.
  for (final (name, size, bounds, angle, laptop) in [
    ('book: the fold down the window', const Size(933, 704), const Rect.fromLTWH(466, 0, 0, 704), 90.0, false),
    ('laptop: the fold across it', const Size(704, 933), const Rect.fromLTWH(0, 466, 704, 0), 90.0, true),
    ('laptop shape, opened flat', const Size(704, 933), const Rect.fromLTWH(0, 466, 704, 0), 178.0, false),
    ('laptop shape, no angle', const Size(704, 933), const Rect.fromLTWH(0, 466, 704, 0), null, false),
  ]) {
    testWidgets('posture, $name', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      t.view.displayFeatures = [
        DisplayFeature(bounds: bounds, type: DisplayFeatureType.fold, state: DisplayFeatureState.postureFlat),
      ];
      addTearDown(t.view.reset);
      (Rect, PostureSource)? found;
      await t.pumpWidget(Builder(builder: (context) {
        found = laptopHinge(context, angle: angle);
        return const SizedBox();
      }));
      expect(found != null, laptop);
      if (laptop) expect(found!.$1.top, 466);
    });
  }
}

void laptopSafeAreaTests() {
  for (final safe in [true, false]) {
    testWidgets('laptop mode ${safe ? 'keeps clear of' : 'covers'} the status bar', (t) async {
      SharedPreferences.setMockInitialValues({'laptopMode': true, 'laptopSafeArea': safe});
      final state = AppState(prefs: await Prefs.load(), engine: Engine());
      final s = RemoteSession.forTest(state.sessions, '123456789')
        ..state = 'connected'
        ..granted = const ['view-screen', 'control-input']
        ..pictureSize = const Size(2560, 1600)
        ..texture = VideoTexture(7, 'c2.test.hevc.decoder', true);
      t.view.physicalSize = const Size(704, 933);
      t.view.devicePixelRatio = 1;
      t.view.padding = const FakeViewPadding(top: 40, bottom: 24);
      t.view.displayFeatures = [
        const DisplayFeature(
          bounds: Rect.fromLTWH(0, 370, 704, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(t.view.reset);
      await t.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ViewerPage(session: s),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final surface = find.byType(RemoteSurface);
      expect(t.getTopLeft(surface).dy, safe ? 40 : 0);
      expect(t.getSize(surface).height, safe ? 330 : 370);
      await t.pumpWidget(const SizedBox());
      state.sessions.dispose();
    });
  }
}
