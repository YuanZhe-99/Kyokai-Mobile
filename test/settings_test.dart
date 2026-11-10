import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/model.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/settings/about_page.dart';
import 'package:kyokai_mobile/ui/settings/networks_page.dart';
import 'package:kyokai_mobile/ui/settings/settings_page.dart';
import 'package:myapps_ui/myapps_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _state([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
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

void _size(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<void> _scrollTo(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 300, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
  await t.pump();
}

void main() {
  testWidgets('an unfolded fold shows a settings page beside the list', (t) async {
    final state = await _state();
    _size(t, const Size(1000, 760));
    await t.pumpWidget(_app(state, const SettingsPage()));
    await t.pump();
    final license = find.byIcon(Icons.gavel_outlined);
    await _scrollTo(t, license);
    await t.tap(license);
    await t.pumpAndSettle();
    expect(find.byType(AppLicensePage), findsOneWidget);
    // Beside the list, not over it.
    expect(find.byIcon(Icons.gavel_outlined), findsOneWidget);
    expect(t.getTopLeft(find.byType(AppLicensePage)).dx, greaterThan(250));
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('a phone opens a settings page over the list', (t) async {
    final state = await _state();
    _size(t, const Size(412, 915));
    await t.pumpWidget(_app(state, const SettingsPage()));
    await t.pump();
    final license = find.byIcon(Icons.gavel_outlined);
    await _scrollTo(t, license);
    await t.tap(license);
    await t.pumpAndSettle();
    expect(find.byType(AppLicensePage), findsOneWidget);
    expect(t.getTopLeft(find.byType(AppLicensePage)).dx, 0);
    expect(find.byType(SettingsPage, skipOffstage: true), findsNothing);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('the navigation position: the side, then the right', (t) async {
    final state = await _state();
    _size(t, const Size(412, 915));
    final prefs = state.prefs;
    expect(prefs.navPlacement, NavPlacement.sideOnWide);
    await t.pumpWidget(_app(state, const SettingsPage()));
    await t.pump();
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget, reason: 'left or right shows for a side option');
    final side = find.text('Side');
    await _scrollTo(t, side);
    await t.tap(side);
    await t.pump();
    expect(prefs.navPlacement, NavPlacement.side);
    await _scrollTo(t, find.text('Right'));
    await t.tap(find.text('Right'));
    await t.pump();
    expect(prefs.railOnRight, isTrue);
    await _scrollTo(t, find.text('Bottom'));
    await t.tap(find.text('Bottom'));
    await t.pump();
    expect(find.byIcon(Icons.swap_horiz), findsNothing);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });

  testWidgets('servers: one field each, Enter adds the next, all saved', (t) async {
    final state = await _state();
    _size(t, const Size(412, 915));
    Json? saved;
    await t.pumpWidget(_app(
      state,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => saved = await showDialog<Json>(context: context, builder: (_) => const NetworkProfileDialog()),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('server0')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('server0')), 'tcp://a.example:11010');
    await t.testTextInput.receiveAction(TextInputAction.next);
    await t.pumpAndSettle();
    final second = find.byKey(const ValueKey('server1'));
    expect(second, findsOneWidget);
    expect(t.widget<TextField>(second).focusNode!.hasFocus, isTrue);
    await t.enterText(second, 'udp://b.example:11010');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(saved?['servers'], ['tcp://a.example:11010', 'udp://b.example:11010']);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}
