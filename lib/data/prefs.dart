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

  /// Where the navigation sits: the bottom bar, the side on wide windows
  /// (an unfolded fold, a tablet; the default), or the side everywhere.
  NavPlacement get navPlacement =>
      NavPlacement.values.asNameMap()[_p.getString('navPlacement')] ?? NavPlacement.sideOnWide;
  set navPlacement(NavPlacement v) => _set('navPlacement', v.name);

  /// The side rail on the window's right instead of its left.
  bool get railOnRight => _p.getBool('railOnRight') ?? false;
  set railOnRight(bool v) => _set('railOnRight', v);

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

  /// Video drawn by an Android SurfaceView in the page (the default), not
  /// through a Flutter texture.
  bool get videoView => _p.getBool('videoView') ?? true;
  set videoView(bool v) => _set('videoView', v);

  /// The debug overlay over the remote screen (decoder, fps, latency).
  bool get overlay => _p.getBool('overlay') ?? false;
  set overlay(bool v) => _set('overlay', v);

  /// The remote picture at the top of the view when it does not fill it.
  bool get pictureTop => _p.getBool('pictureTop') ?? false;
  set pictureTop(bool v) => _set('pictureTop', v);

  /// A foldable half-open with its hinge across (laptop posture): the
  /// picture above the hinge, the keyboard and a touchpad below it.
  bool get laptopMode => _p.getBool('laptopMode') ?? false;
  set laptopMode(bool v) => _set('laptopMode', v);

  /// Laptop mode keeps clear of the status bar and the navigation bar.
  bool get laptopSafeArea => _p.getBool('laptopSafeArea') ?? true;
  set laptopSafeArea(bool v) => _set('laptopSafeArea', v);

  /// Pointer speed of the trackpad mode.
  double get pointerSpeed => _p.getDouble('pointerSpeed') ?? 1.6;
  set pointerSpeed(double v) => _set('pointerSpeed', v);

  /// The trackpad cursor's diameter, in logical pixels.
  static const cursorMin = 10.0;
  static const cursorMax = 34.0;
  double get cursorSize => _p.getDouble('cursorSize') ?? 16;
  set cursorSize(double v) => _set('cursorSize', v);

  /// Where the folded toolbar's handle sits over the picture, as fractions
  /// of the room it moves in (x 0 left to 1 right, y 0 top to 1 bottom).
  Offset get handle => Offset(_p.getDouble('handleX') ?? 0.5, _p.getDouble('handleY') ?? 0);
  set handle(Offset v) {
    _p.setDouble('handleX', v.dx);
    _p.setDouble('handleY', v.dy);
    notifyListeners();
  }

  /// The keyboard's system layout picked by hand for a host ('windows',
  /// 'macos', 'linux'); null to follow what the host reports. [key] names
  /// the host and how it is reached (a NanoKVM's machine is not the host).
  String? keyboardOs(String key) => _p.getString('keyboardOs.$key');
  void setKeyboardOs(String key, String? os) => _set('keyboardOs.$key', os);

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
