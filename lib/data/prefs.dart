// The app's own preferences (not the core's): appearance, language, the
// keyboard's layout and the viewer's pointer mode. The core keeps its own
// settings (networks, devices, keys) in its state directory.

import 'package:flutter/material.dart';
import 'package:myapps_ui/myapps_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PointerMode { trackpad, touch }

class Prefs extends ChangeNotifier {
  Prefs._(this._p);

  static Future<Prefs> load() async => Prefs._(await SharedPreferences.getInstance());

  final SharedPreferences _p;

  ThemeMode get themeMode => ThemeMode.values.byName(_p.getString('theme') ?? 'system');
  set themeMode(ThemeMode v) => _set('theme', v.name);

  AppUiStyle get style => AppUiStyle.values.byName(_p.getString('style') ?? 'expressive');
  set style(AppUiStyle v) => _set('style', v.name);

  /// Wallpaper colours (Android 12+) instead of Kyokai's own.
  bool get dynamicColor => _p.getBool('dynamicColor') ?? false;
  set dynamicColor(bool v) => _set('dynamicColor', v);

  /// A language tag, or null to follow the system.
  String? get locale => _p.getString('locale');
  set locale(String? v) => _set('locale', v);

  /// Home also lists the Kyokai devices the joined networks reach that
  /// this phone never connected to.
  bool get othersInNetworks => _p.getBool('othersInNetworks') ?? true;
  set othersInNetworks(bool v) => _set('othersInNetworks', v);

  bool get splitKeyboard => _p.getBool('splitKeyboard') ?? false;
  set splitKeyboard(bool v) => _set('splitKeyboard', v);

  PointerMode get pointerMode => PointerMode.values.byName(_p.getString('pointer') ?? 'trackpad');
  set pointerMode(PointerMode v) => _set('pointer', v.name);

  /// The debug overlay over the remote screen (decoder, fps, latency).
  bool get overlay => _p.getBool('overlay') ?? false;
  set overlay(bool v) => _set('overlay', v);

  /// Pointer speed of the trackpad mode.
  double get pointerSpeed => _p.getDouble('pointerSpeed') ?? 1.6;
  set pointerSpeed(double v) => _set('pointerSpeed', v);

  bool get sound => _p.getBool('sound') ?? true;
  set sound(bool v) => _set('sound', v);

  /// Devices' order and pins are the core's; recent connections by address.
  List<String> get recent => _p.getStringList('recent') ?? const [];
  void addRecent(String target) {
    final list = [target, ...recent.where((r) => r != target)].take(8).toList();
    _p.setStringList('recent', list);
    notifyListeners();
  }

  void _set(String key, Object? v) {
    switch (v) {
      case null:
        _p.remove(key);
      case final String s:
        _p.setString(key, s);
      case final bool b:
        _p.setBool(key, b);
      case final double d:
        _p.setDouble(key, d);
    }
    notifyListeners();
  }
}
