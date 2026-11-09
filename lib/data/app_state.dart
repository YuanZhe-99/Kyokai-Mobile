// The app's state: its preferences, the core (started once, at launch) and
// the open sessions, shared down the tree by [AppScope].

import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'prefs.dart';
import 'sessions.dart';

class AppState {
  AppState({required this.prefs, required this.engine}) : sessions = Sessions(engine);

  final Prefs prefs;
  final Engine engine;
  final Sessions sessions;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.state, required super.child});

  final AppState state;

  static AppState of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.state;

  @override
  bool updateShouldNotify(AppScope oldWidget) => state != oldWidget.state;
}
