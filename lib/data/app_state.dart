// The app's state: its preferences, the core (started once, at launch) and
// the open sessions, shared down the tree by [AppScope].

import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'prefs.dart';
import 'services.dart';
import 'sessions.dart';

class AppState {
  AppState({required this.prefs, required this.engine}) : sessions = Sessions(engine, store: prefs) {
    sessions.videoView = prefs.videoView;
    prefs.addListener(() => sessions.videoView = prefs.videoView);
    services.addListener(() => sessions.serviceTitles = services.liveTitles);
  }

  final Prefs prefs;
  final Engine engine;
  final Sessions sessions;

  /// SSH, files, Remote Desktop and VNC open from this phone.
  final services = ServiceSessions();
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.state, required super.child});

  final AppState state;

  static AppState of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.state;

  @override
  bool updateShouldNotify(AppScope oldWidget) => state != oldWidget.state;
}
