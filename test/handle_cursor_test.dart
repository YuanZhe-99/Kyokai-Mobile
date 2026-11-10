import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/core/native.dart';
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/data/sessions.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/settings/cursor_size.dart';
import 'package:kyokai_mobile/ui/viewer/surface.dart';
import 'package:kyokai_mobile/ui/viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(AppState state, Widget home) => AppScope(
  state: state,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

Future<(AppState, RemoteSession)> _session() async {
  final state = AppState(prefs: await Prefs.load(), engine: Engine());
  final s = RemoteSession.forTest(state.sessions, '123456789')
    ..state = 'connected'
    ..granted = const ['view-screen', 'control-input']
    ..pictureSize = const Size(2560, 1600)
    ..texture = VideoTexture(7, 'c2.test.hevc.decoder', true);
  return (state, s);
}

void main() {
  testWidgets('the toolbar handle drags to a side, stays there, and still opens the toolbar', (t) async {
    SharedPreferences.setMockInitialValues({});
    final (state, s) = await _session();
    t.view.physicalSize = const Size(915, 412);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(state, ViewerPage(session: s)));
    await t.pump();
    final handle = find.byKey(const ValueKey('pull'));
    // Fold the toolbar if it starts open.
    if (handle.evaluate().isEmpty) {
      await t.tap(find.byIcon(Icons.expand_less));
      await t.pump(const Duration(milliseconds: 300));
    }
    final start = t.getCenter(handle);
    expect(start.dx, closeTo(457.5, 2), reason: 'it starts at the top middle');
    final g = await t.startGesture(start);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(30, 15));
      await t.pump();
    }
    final mid = t.getCenter(handle);
    expect(mid.dx, greaterThan(start.dx + 200), reason: 'it follows the finger');
    await g.up();
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    final end = t.getCenter(handle);
    expect(end.dx, greaterThan(860), reason: 'let go right of the middle, it snaps to the right side');
    expect(end.dy, closeTo(mid.dy, 1), reason: 'and keeps its height');
    expect(state.prefs.handle.dx, 1);
    await t.tap(handle);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('the cursor size shows in its preview and on the remote screen', (t) async {
    SharedPreferences.setMockInitialValues({});
    final (state, s) = await _session();
    final prefs = state.prefs;
    await t.pumpWidget(_app(
      state,
      Scaffold(body: ListenableBuilder(listenable: prefs, builder: (_, _) => CursorSizeTile(prefs: prefs))),
    ));
    Size preview() => t.getSize(find.descendant(of: find.byKey(const ValueKey('cursorPreview')), matching: find.byType(CursorRing)));
    expect(preview().width, 16);
    // The references under the slider's start, middle and end.
    await t.tap(find.byKey(const ValueKey('cursorRef${Prefs.cursorMax}')));
    await t.pump();
    expect(prefs.cursorSize, Prefs.cursorMax);
    expect(preview().width, Prefs.cursorMax);
    await t.tap(find.byKey(const ValueKey('cursorRef${Prefs.cursorMin}')));
    await t.pump();
    expect(preview().width, Prefs.cursorMin);

    prefs.cursorSize = 24;
    t.view.physicalSize = const Size(1000, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(state, ViewerPage(session: s)));
    await t.pump();
    expect(t.getSize(find.descendant(of: find.byType(RemoteSurface), matching: find.byType(CursorRing))).width, 24);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}
