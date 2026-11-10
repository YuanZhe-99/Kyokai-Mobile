// The viewer as the app shows it: its theme, dark, in Chinese, pushed over
// the shell, fed what a Windows host sends.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/data/sessions.dart';
import 'package:kyokai_mobile/ui/shell/app.dart';
import 'package:kyokai_mobile/ui/viewer/surface.dart';
import 'package:kyokai_mobile/ui/viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _p(int kind, Object body) => Uint8List.fromList([kind, ...utf8.encode(jsonEncode(body))]);

void main() {
  testWidgets('the picture area appears in the app', (t) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), (call) async {
      if (call.method == 'videoOpen') {
        return {'texture': 7, 'decoder': 'c2.qti.hevc.decoder', 'hardware': true, 'view': (call.arguments as Map)['view']};
      }
      return null;
    });
    messenger.setMockMessageHandler('kyokai/video', (m) async => ByteData(1));
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), null);
      messenger.setMockMessageHandler('kyokai/video', null);
    });
    SharedPreferences.setMockInitialValues({'overlay': true, 'theme': 'dark', 'locale': 'zh'});
    final state = AppState(prefs: await Prefs.load(), engine: Engine()..started = true);
    t.view.physicalSize = const Size(2000, 1510);
    t.view.devicePixelRatio = 2;
    t.view.padding = const FakeViewPadding(top: 80, bottom: 40);
    addTearDown(t.view.reset);
    await t.pumpWidget(KyokaiApp(state: state));
    await t.pumpAndSettle();
    final s = RemoteSession.forTest(state.sessions, '123456789');
    t.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => ViewerPage(session: s)));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    s
      ..state = 'connected'
      ..granted = const ['view-screen', 'control-input', 'hear-sound', 'clipboard'];
    s.packetForTest(_p(11, {'codecs': ['hevc', 'h264']}));
    s.packetForTest(_p(1, {'codec': 'hevc', 'width': 2560, 'height': 1600, 'encoder': 'Media Foundation', 'hardware': true}));
    s.packetForTest(_p(9, {'ctrl_alt_del': true, 'blocked': false, 'privacy': false}));
    s.packetForTest(_p(15, {'paused': false}));
    s.packetForTest(_p(7, {'x': 0.31, 'y': 0.72, 'visible': true}));
    s.packetForTest(_p(4, {'delay_ms': 31, 'fps': 30, 'frames': 12, 'bitrate': 2500000, 'encode_ms': 6, 'video': 'hevc'}));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(t.takeException(), isNull);
    expect(find.byType(RemoteSurface), findsOneWidget);
    final size = t.getSize(find.byType(RemoteSurface));
    expect(size.height, greaterThan(200), reason: 'surface $size');
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}
