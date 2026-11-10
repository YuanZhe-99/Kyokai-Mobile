// Kyokai for Android: logs first (so a failed start leaves a trace), then
// the app's preferences, then the core, started while the start gate shows.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'build_info.dart';
import 'core/native.dart';
import 'data/app_state.dart';
import 'data/engine.dart';
import 'data/log.dart';
import 'data/prefs.dart';
import 'ui/shell/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.init();
  Log.info('app', 'Kyokai-Mobile $appVersion ($buildNumber, $buildCommit)');
  FlutterError.onError = (details) {
    Log.error('flutter', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  // A widget that fails to build says why where it would be, in release
  // builds too: a blank area tells a tester nothing.
  ErrorWidget.builder = (details) => ColoredBox(
    color: const Color(0xFF8B0000),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        '${details.exception}',
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12),
        textDirection: TextDirection.ltr,
      ),
    ),
  );
  final prefs = await Prefs.load();
  Native.listen();
  final engine = Engine();
  final state = AppState(prefs: prefs, engine: engine);
  PlatformDispatcher.instance.onError = (error, stack) {
    Log.error('app', error, stack);
    return true;
  };
  runApp(KyokaiApp(state: state));
  unawaited(engine.begin());
}
