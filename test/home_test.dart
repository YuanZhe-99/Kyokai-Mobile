import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/data/app_state.dart';
import 'package:kyokai_mobile/data/engine.dart';
import 'package:kyokai_mobile/data/prefs.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/home/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // An unfolded fold on its side: the keyboard takes more than half the
  // height, which alone would end the split layout.
  testWidgets('the search field keeps its keyboard on an unfolded fold', (t) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(prefs: await Prefs.load(), engine: Engine());
    t.view.physicalSize = const Size(1000, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      state: state,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HomePage()),
      ),
    ));
    await t.tap(find.byType(SearchBar));
    await t.pump();
    final field = find.descendant(of: find.byType(SearchBar), matching: find.byType(EditableText));
    expect(t.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    t.view.viewInsets = const FakeViewPadding(bottom: 420);
    await t.pump();
    await t.pump();
    expect(t.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    await t.pumpWidget(const SizedBox());
    state.sessions.dispose();
  });
}
