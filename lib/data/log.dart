// The app's log: a file in the app's support directory, kept to the last
// two files of 1 MB, and shared on request (Settings › Diagnostics) with the
// core's own logs. Nothing secret is written: callers log events and
// errors, never passwords, keys or network secrets.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

abstract final class Log {
  static IOSink? _sink;
  static File? _file;
  static int _size = 0;
  static const _max = 1 << 20;

  /// Where the app's and the core's logs go.
  static late final Directory dir;

  static Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    dir = Directory('${base.path}/logs');
    await dir.create(recursive: true);
    _file = File('${dir.path}/app.log');
    _size = await _file!.exists() ? await _file!.length() : 0;
    _sink = _file!.openWrite(mode: FileMode.append);
    FlutterError.onError = (e) {
      FlutterError.presentError(e);
      error('flutter', e.exceptionAsString(), e.stack);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      error('uncaught', e, st);
      return false;
    };
  }

  static void info(String tag, Object message) => _write('I', tag, '$message');

  static void error(String tag, Object error, [StackTrace? stack]) =>
      _write('E', tag, stack == null ? '$error' : '$error\n$stack');

  static void _write(String level, String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} $level $tag: $message\n';
    if (kDebugMode) debugPrint(line.trimRight());
    final sink = _sink;
    if (sink == null) return;
    sink.write(line);
    _size += line.length;
    if (_size > _max) unawaited(_rotate());
  }

  static Future<void> _rotate() async {
    final old = _sink;
    _sink = null;
    await old?.flush();
    await old?.close();
    final f = _file!;
    final prev = File('${dir.path}/app.1.log');
    if (await prev.exists()) await prev.delete();
    await f.rename(prev.path);
    _file = File('${dir.path}/app.log');
    _size = 0;
    _sink = _file!.openWrite(mode: FileMode.append);
  }

  /// Shares every log (the app's and the core's) through the system's
  /// share sheet, with a header naming the build.
  static Future<void> share(String header) async {
    await _sink?.flush();
    final files = <XFile>[];
    final summary = File('${dir.path}/about.txt');
    await summary.writeAsString(header);
    files.add(XFile(summary.path));
    await for (final e in dir.list(recursive: true)) {
      if (e is File && e.path != summary.path && await e.length() > 0) files.add(XFile(e.path));
    }
    await Share.shareXFiles(files, subject: 'Kyokai logs');
  }
}
