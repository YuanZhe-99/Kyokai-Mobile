// Clipboard history, images from the host, the host's AI task history and
// switching between open pictures (0.1.1).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/core/ffi.dart' as core;
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/data/services.dart';
import 'package:kyokai_mobile/data/sessions.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/ai/ai_history.dart';
import 'package:kyokai_mobile/ui/home/sessions_page.dart';
import 'package:kyokai_mobile/ui/viewer/clip_history.dart';
import 'package:kyokai_mobile/ui/viewer/session_sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _packet(int kind, Map<String, Object?> body) => Uint8List.fromList([kind, ...utf8.encode(jsonEncode(body))]);

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return AppState(prefs: await Prefs.load(), engine: Engine());
}

Widget _app(AppState state, Widget home) => AppScope(
  state: state,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  late List<MethodCall> native;
  String? clipboardText;
  setUp(() {
    native = [];
    clipboardText = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), (call) async {
      native.add(call);
      return call.method == 'setClipImage' ? 'content://x@1' : null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardText = (call.arguments as Map)['text'] as String?;
      return null;
    });
  });
  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('kyokai/native'), null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('what crossed the clipboard is kept, newest first; the host\'s image goes on the phone', (t) async {
    final state = await _state();
    final s = RemoteSession.forTest(state.sessions, '123456789');
    // A 1×1 PNG.
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    s.packetForTest(_packet(core.Packet.clipboard, {'from': 'controller', 'at': 1000, 'text': 'from the phone'}));
    s.packetForTest(_packet(core.Packet.clipboard, {'from': 'host', 'at': 2000, 'text': 'from the host'}));
    s.packetForTest(_packet(core.Packet.clipboard, {'from': 'host', 'at': 3000, 'png': png}));
    s.packetForTest(_packet(core.Packet.clipboard, {'from': 'host', 'at': 4000, 'files': [{'name': 'a.txt'}]}));
    await t.pump();
    final h = state.sessions.clipHistory;
    expect(h.length, 4);
    expect(h.first.files, 1);
    expect(h[1].png, isNotNull);
    expect(h[2].text, 'from the host');
    expect(h[3].fromHost, isFalse);
    // The host's text and image reach the phone's clipboard; the phone's own
    // copy is not written back.
    expect(clipboardText, 'from the host');
    expect(native.where((c) => c.method == 'setClipImage'), hasLength(1));

    await t.pumpWidget(_app(state, const ClipHistoryPage()));
    await t.pump();
    expect(find.text('from the phone'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // Copying the phone's entry again.
    await t.tap(find.text('from the phone'));
    await t.pump();
    expect(clipboardText, 'from the phone');
    await t.tap(find.byIcon(Icons.delete_sweep_outlined));
    await t.pump();
    expect(state.sessions.clipHistory, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5)); // the snack bar's timer
    state.sessions.dispose();
  });

  testWidgets('a host\'s tasks are kept by id, newest first', (t) async {
    final state = await _state();
    final s = RemoteSession.forTest(state.sessions, '123456789');
    s.packetForTest(_packet(core.Packet.aiTask, {'id': 1, 'instruction': 'first', 'state': 'running', 'updated': 10}));
    s.packetForTest(_packet(core.Packet.aiTask, {'id': 1, 'instruction': 'first', 'state': 'done', 'updated': 20, 'text': 'all done'}));
    s.packetForTest(_packet(core.Packet.aiTask, {'id': 2, 'instruction': 'second', 'state': 'failed', 'updated': 30}));
    final tasks = state.sessions.aiHistory('123456789');
    expect(tasks.map((e) => e['id']), [2, 1]);
    expect(tasks.last['state'], 'done');

    await t.pumpWidget(_app(state, const Scaffold(body: AiHistoryList(deviceId: '123456789'))));
    await t.pump();
    expect(find.text('second'), findsOneWidget);
    await t.tap(find.text('first'));
    await t.pumpAndSettle();
    expect(find.text('all done'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('the session menu offers the clipboard history and the other open picture', (t) async {
    final state = await _state();
    final a = RemoteSession.forTest(state.sessions, '123456789')
      ..state = 'connected'
      ..id = 1;
    final b = RemoteSession.forTest(state.sessions, '987654321')
      ..state = 'connected'
      ..id = 2;
    state.sessions.open.addAll([a, b]);
    late BuildContext ctx;
    await t.pumpWidget(_app(state, Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    })));
    showSessionMenu(ctx, a, onQuality: () {}, onAi: () {}, onTypeText: () {}, onDisconnect: () async {});
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('clipHistory')), findsOneWidget);
    expect(find.byKey(const ValueKey('switchTo2')), findsOneWidget);
    expect(find.byKey(const ValueKey('switchTo1')), findsNothing);
    state.sessions.open.clear();
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('services kept open are listed beside the sessions, and leave when they end', (t) async {
    final state = await _state();
    final ssh = ServiceSession('123456789', ServiceKind.ssh, 'Work PC')
      ..state = 'connected'
      ..id = 4;
    state.services.add(ssh);
    await t.pumpWidget(_app(state, const SessionsPage()));
    await t.pump();
    expect(find.byKey(const ValueKey('service4')), findsOneWidget);
    expect(find.text('Work PC'), findsOneWidget);
    await state.services.pageClosed(ssh); // still connected: kept
    expect(state.services.open, [ssh]);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('service4')), matching: find.byIcon(Icons.close)));
    await t.pump();
    expect(state.services.open, isEmpty);
    expect(find.byKey(const ValueKey('service4')), findsNothing);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}
