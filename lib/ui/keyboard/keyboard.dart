// The on-screen keyboard: Gboard's look in Material 3 tones, with a
// computer's keys (Esc, Tab, Ctrl, Alt, Win/Command/Super, the arrows,
// F1–F12, …). Every key goes by its place as a set-1 scan code (keys.dart),
// so the host's own layout and input method decide what it types: Chinese
// and Japanese are typed with the host's input method.
//
// Phones get Gboard's four rows under a strip of computer keys. Wide
// screens get either the full computer keyboard or the split one: two
// phone-sized halves at the edges for two thumbs, a touchpad between them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'keys.dart';

/// Where the keyboard's keys go: one scan-code press or release, with this
/// side's CapsLock (the host matches its own to it before a letter).
typedef ScanSink = void Function(int code, bool down, {required bool caps});

/// The modifiers the keyboard latches: tapped, one holds for the next key;
/// tapped twice, it stays until tapped again; held while another key is
/// pressed, it is held on the host as long as the finger stays.
enum Mod {
  shift(Scan.lshift),
  ctrl(Scan.lctrl),
  alt(Scan.lalt),
  win(Scan.lwin);

  const Mod(this.code);
  final int code;
}

/// The touchpad between the halves of the split keyboard.
abstract interface class Touchpad {
  /// The pointer moved by this many logical pixels.
  void move(Offset delta);

  /// A button went down or up (0 left, 1 right).
  void button(int button, bool down);

  /// Two fingers scrolled by this many logical pixels.
  void scroll(Offset delta);
}

enum _Latch { off, once, locked }

enum KeyPage { letters, symbols, more, function }

sealed class _Action {
  const _Action();
}

/// Types a character by its US key (letters follow Shift and CapsLock).
final class _Char extends _Action {
  const _Char(this.char);
  final String char;
}

/// A named key by scan code.
final class _Code extends _Action {
  const _Code(this.code, {this.repeat = false});
  final int code;
  final bool repeat;
}

/// A shortcut: the modifiers held around one key.
final class _Combo extends _Action {
  const _Combo(this.mods, this.code, {this.special});
  final List<int> mods;
  final int code;

  /// Sent instead of keys when the session offers it (Ctrl+Alt+Del).
  final String? special;
}

final class _ModKey extends _Action {
  const _ModKey(this.mod);
  final Mod mod;
}

final class _Go extends _Action {
  const _Go(this.page);
  final KeyPage page;
}

final class _Hide extends _Action {
  const _Hide();
}

final class _Gap extends _Action {
  const _Gap();
}

/// One key on a row: what it shows, what it does, its share of the row and
/// whether it is drawn as a function key (the tonal keys).
final class _K {
  const _K(this.label, this.action, {this.flex = 10, this.special = false, this.icon});
  final String label;
  final _Action action;
  final int flex;
  final bool special;
  final IconData? icon;
}

_K _c(String c, {int flex = 10}) => _K(c, _Char(c), flex: flex);
_K _code(String label, int code, {int flex = 10, IconData? icon, bool repeat = false}) =>
    _K(label, _Code(code, repeat: repeat), flex: flex, special: true, icon: icon);
const _gap5 = _K('', _Gap(), flex: 5);

class RemoteKeyboard extends StatefulWidget {
  const RemoteKeyboard({
    super.key,
    required this.send,
    required this.onHide,
    this.hostOs = HostOs.windows,
    this.target = KeyTarget.kyokai,
    this.split = false,
    this.onSplitChanged,
    this.touchpad,
    this.onSpecial,
  });

  final ScanSink send;
  final VoidCallback onHide;
  final HostOs hostOs;
  final KeyTarget target;

  /// On a wide screen: the split keyboard rather than the full one.
  final bool split;
  final ValueChanged<bool>? onSplitChanged;

  /// Drives the pointer from the split keyboard's middle.
  final Touchpad? touchpad;

  /// A shortcut the session performs itself (`ctrl_alt_del`); keys are sent
  /// when it is null or answers false.
  final bool Function(String action)? onSpecial;

  /// Wide enough for the full or split keyboard.
  static bool isWide(double width) => width >= 600;

  /// The keyboard's height at this width, for layouts that reserve it.
  static double heightFor(double width, {bool split = false}) =>
      36 + 40 + 4 + (isWide(width) ? (split ? 5 * 46.0 : 5 * 50.0) : 4 * 46.0);

  @override
  State<RemoteKeyboard> createState() => RemoteKeyboardState();
}

class RemoteKeyboardState extends State<RemoteKeyboard> {
  final _latch = {for (final m in Mod.values) m: _Latch.off};

  /// Modifier keys a finger holds now.
  final _held = <Mod>{};

  /// Modifiers down on the host for a finger that holds them: they went
  /// down with the first other key pressed meanwhile, so a lone tap (the
  /// Win key opening the Start menu) never reaches the host.
  final _hostHeld = <Mod>{};
  bool _caps = false;
  KeyPage _page = KeyPage.letters;
  Timer? _repeat;
  final _lastTap = <Mod, DateTime>{};

  KeyPage get page => _page;

  void _send(int code, bool down) => widget.send(code, down, caps: _caps);

  /// Lets go of every key the keyboard holds on the host (it hides, the
  /// session ends) and of every latch.
  void releaseAll() {
    _repeat?.cancel();
    for (final m in _hostHeld) {
      _send(m.code, false);
    }
    _hostHeld.clear();
    _held.clear();
    for (final m in Mod.values) {
      _latch[m] = _Latch.off;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  bool _active(Mod m) => _latch[m] != _Latch.off || _held.contains(m);

  void _tapMod(Mod m) {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final last = _lastTap[m];
    _lastTap[m] = now;
    final twice = last != null && now.difference(last) < const Duration(milliseconds: 350);
    setState(() {
      if (m == Mod.shift && (twice || _caps)) {
        // Gboard's caps lock: Shift tapped twice, and once more to end it.
        _latch[m] = _Latch.off;
        _caps = !_caps;
        return;
      }
      _latch[m] = switch (_latch[m]!) {
        _Latch.off => _Latch.once,
        _Latch.once => twice ? _Latch.locked : _Latch.off,
        _Latch.locked => _Latch.off,
      };
    });
  }

  /// The latched modifiers no finger holds: they go down with a key and up
  /// after it.
  List<Mod> get _latched => [
    for (final m in Mod.values)
      if (_latch[m] != _Latch.off && !_held.contains(m)) m,
  ];

  void _press(int code, {bool shift = false}) {
    for (final m in _held.difference(_hostHeld)) {
      _send(m.code, true);
      _hostHeld.add(m);
    }
    for (final m in _latched) {
      _send(m.code, true);
    }
    if (shift && !_active(Mod.shift)) _send(Scan.lshift, true);
    _send(code, true);
  }

  void _release(int code, {bool shift = false}) {
    _send(code, false);
    if (shift && !_active(Mod.shift)) _send(Scan.lshift, false);
    for (final m in _latched.reversed) {
      _send(m.code, false);
    }
    setState(() {
      for (final m in Mod.values) {
        if (_latch[m] == _Latch.once) _latch[m] = _Latch.off;
      }
    });
  }

  (int, bool)? _resolve(_Action a) => switch (a) {
    _Char(:final char) => usKeys[char.toLowerCase()] ?? usKeys[char],
    _Code(:final code) => (code, false),
    _ => null,
  };

  void _combo(_Combo c) {
    if (c.special != null && (widget.onSpecial?.call(c.special!) ?? false)) return;
    for (final m in c.mods) {
      _send(m, true);
    }
    _send(c.code, true);
    _send(c.code, false);
    for (final m in c.mods.reversed) {
      _send(m, false);
    }
  }

  void _keyDown(_K k) {
    HapticFeedback.lightImpact();
    switch (k.action) {
      case _ModKey(:final mod):
        setState(() => _held.add(mod));
      case _Go() || _Hide() || _Gap() || _Combo():
        break;
      case final a:
        final r = _resolve(a);
        if (r == null) return;
        final (code, shift) = r;
        _press(code, shift: shift);
        if (a is _Code && a.repeat) {
          _repeat?.cancel();
          _repeat = Timer(const Duration(milliseconds: 400), () {
            _repeat = Timer.periodic(const Duration(milliseconds: 50), (_) {
              // Typematic: the key pressed again while held, as a keyboard does.
              _send(code, true);
            });
          });
        }
    }
  }

  void _keyUp(_K k) {
    _repeat?.cancel();
    _repeat = null;
    switch (k.action) {
      case _ModKey(:final mod):
        _held.remove(mod);
        if (_hostHeld.remove(mod)) {
          _send(mod.code, false);
          setState(() {});
        } else if (mod == Mod.win && widget.hostOs != HostOs.macos && _latch[mod] == _Latch.off) {
          // Win (Super) tapped alone is a key of its own on Windows and
          // Linux: it opens Start or the overview. Held, it still makes a
          // shortcut with the keys pressed meanwhile.
          _send(mod.code, true);
          _send(mod.code, false);
        } else {
          _tapMod(mod);
        }
      case _Go(:final page):
        HapticFeedback.selectionClick();
        setState(() => _page = page);
      case _Hide():
        releaseAll();
        widget.onHide();
      case _Gap():
        break;
      case final _Combo c:
        _combo(c);
      case final a:
        final r = _resolve(a);
        if (r == null) return;
        final (code, shift) = r;
        _release(code, shift: shift);
        if ((_page == KeyPage.symbols || _page == KeyPage.more) && a is _Char && a.char == ' ') {
          // Gboard goes back to letters after a space typed on the symbols.
          setState(() => _page = KeyPage.letters);
        }
    }
  }

  // ---- Layout -----------------------------------------------------------

  bool get _mac => widget.hostOs == HostOs.macos;

  String _modLabel(Mod m) => switch ((m, widget.hostOs)) {
    (Mod.shift, _) => 'Shift',
    (Mod.ctrl, HostOs.macos) => '⌃ Ctrl',
    (Mod.ctrl, _) => 'Ctrl',
    (Mod.alt, HostOs.macos) => '⌥ Opt',
    (Mod.alt, _) => 'Alt',
    (Mod.win, HostOs.macos) => '⌘ Cmd',
    (Mod.win, HostOs.linux) => 'Super',
    (Mod.win, _) => 'Win',
  };

  _K _mod(Mod m, {int flex = 10}) => _K(_modLabel(m), _ModKey(m), flex: flex, special: true);

  /// The modifiers in the host's order: Ctrl Win Alt on a PC, Ctrl Opt Cmd
  /// on a Mac.
  List<Mod> get _modOrder => _mac ? const [Mod.ctrl, Mod.alt, Mod.win] : const [Mod.ctrl, Mod.win, Mod.alt];

  /// The computer's keys over the layout, as Gboard's suggestion strip.
  List<_K> get _strip => [
    _code('Esc', Scan.esc),
    _code('Tab', Scan.tab, icon: Icons.keyboard_tab),
    for (final m in _modOrder) _mod(m, flex: _mac ? 13 : 10),
    _code('←', Scan.left, icon: Icons.keyboard_arrow_left, repeat: true),
    _code('↑', Scan.up, icon: Icons.keyboard_arrow_up, repeat: true),
    _code('↓', Scan.down, icon: Icons.keyboard_arrow_down, repeat: true),
    _code('→', Scan.right, icon: Icons.keyboard_arrow_right, repeat: true),
    _K('Fn', _Go(_page == KeyPage.function ? KeyPage.letters : KeyPage.function), special: true),
  ];

  _K get _shiftKey => _K(
    'Shift',
    const _ModKey(Mod.shift),
    flex: 15,
    special: true,
    icon: _caps ? Icons.keyboard_capslock : Icons.arrow_upward,
  );
  _K get _back => _code('⌫', Scan.backspace, flex: 15, icon: Icons.backspace_outlined, repeat: true);
  _K get _enter => _code('⏎', Scan.enter, flex: 15, icon: Icons.keyboard_return);
  _K get _abc => _K(
    _page == KeyPage.letters ? '?123' : 'ABC',
    _Go(_page == KeyPage.letters ? KeyPage.symbols : KeyPage.letters),
    flex: 15,
    special: true,
  );
  static const _hide = _K('', _Hide(), special: true, icon: Icons.keyboard_hide_outlined);
  List<_K> get _digits => [for (final d in '1234567890'.split('')) _c(d)];

  /// The shortcuts on the Fn page, in the host's own keys.
  List<_K> get _shortcuts {
    final cmd = _mac ? Scan.lwin : Scan.lctrl;
    final p = _mac ? '⌘' : 'Ctrl+';
    _K s(String label, List<int> mods, int code, {String? special}) =>
        _K(label, _Combo(mods, code, special: special), special: true);
    return [
      s('${p}C', [cmd], usKeys['c']!.$1),
      s('${p}V', [cmd], usKeys['v']!.$1),
      s('${p}X', [cmd], usKeys['x']!.$1),
      s('${p}Z', [cmd], usKeys['z']!.$1),
      s('${p}A', [cmd], usKeys['a']!.$1),
      if (_mac) ...[
        s('⌘Tab', [Scan.lwin], Scan.tab),
        s('⌘Space', [Scan.lwin], Scan.space),
        s('⌥⌘Esc', [Scan.lalt, Scan.lwin], Scan.esc),
      ] else ...[
        s('Alt+Tab', [Scan.lalt], Scan.tab),
        s(widget.hostOs == HostOs.linux ? 'Super' : 'Win+D', [Scan.lwin], widget.hostOs == HostOs.linux ? 0 : 0x20),
        s('Ctrl+Alt+Del', [Scan.lctrl, Scan.lalt], Scan.delete, special: 'ctrl_alt_del'),
      ],
    ].map((k) {
      // Super alone: the key itself, tapped.
      final a = k.action;
      return a is _Combo && a.code == 0 ? _code('Super', Scan.lwin) : k;
    }).toList();
  }

  List<List<_K>> get _fnRows => [
    [for (var n = 1; n <= 12; n++) _code('F$n', Scan.f(n))],
    [
      _code('Ins', Scan.insert),
      _code('Home', Scan.home),
      _code('PgUp', Scan.pageUp, repeat: true),
      _code('PrtSc', Scan.printScreen),
      _code('Pause', Scan.pause),
      _code('Menu', Scan.menu),
    ],
    [
      _code('Del', Scan.delete, repeat: true),
      _code('End', Scan.end),
      _code('PgDn', Scan.pageDown, repeat: true),
      _code('Caps', Scan.caps),
      _code('NumLk', Scan.numLock),
      _code('ScrLk', Scan.scrollLock),
    ],
    _shortcuts,
    [
      const _K('ABC', _Go(KeyPage.letters), flex: 15, special: true),
      _mod(Mod.shift, flex: 15),
      _code('RCtrl', Scan.rctrl),
      _code(_mac ? 'R⌥' : 'RAlt', Scan.ralt),
      _code(switch (widget.hostOs) {
        HostOs.macos => 'R⌘',
        HostOs.linux => 'RSuper',
        HostOs.windows => 'RWin',
      }, Scan.rwin, flex: 12),
      _back,
      _enter,
    ],
  ];

  /// Gboard's phone rows (without the strip).
  List<List<_K>> get _phoneRows => switch (_page) {
    KeyPage.letters => [
      [for (final c in 'qwertyuiop'.split('')) _c(c)],
      [_gap5, for (final c in 'asdfghjkl'.split('')) _c(c), _gap5],
      [_shiftKey, for (final c in 'zxcvbnm'.split('')) _c(c), _back],
      [_abc, _c(','), _hide, _K('', const _Char(' '), flex: 40), _c('.'), _enter],
    ],
    KeyPage.symbols => [
      _digits,
      [for (final c in r'@#$_&-+()/'.split('')) _c(c)],
      [const _K('=\\<', _Go(KeyPage.more), flex: 15, special: true), for (final c in '*"\':;!?'.split('')) _c(c), _back],
      [_abc, _c(','), _hide, _K('', const _Char(' '), flex: 40), _c('.'), _enter],
    ],
    KeyPage.more => [
      [for (final c in r'~`|\{}[]^%'.split('')) _c(c)],
      [for (final c in '<>=_-+@#&'.split('')) _c(c), _code('Del', Scan.delete, repeat: true)],
      [const _K('?123', _Go(KeyPage.symbols), flex: 15, special: true), for (final c in '.,!?/;:'.split('')) _c(c), _back],
      [_abc, _c(','), _hide, _K('', const _Char(' '), flex: 40), _c('.'), _enter],
    ],
    KeyPage.function => _fnRows,
  };

  /// The full computer keyboard for a wide screen.
  List<List<_K>> get _fullRows {
    if (_page != KeyPage.letters) return _phoneRows;
    final left = [for (final m in _modOrder) _mod(m, flex: 13)];
    return [
      [_c('`'), ..._digits, _c('-'), _c('='), _code('⌫', Scan.backspace, flex: 20, icon: Icons.backspace_outlined, repeat: true)],
      [_code('Tab', Scan.tab, flex: 15), for (final c in 'qwertyuiop'.split('')) _c(c), _c('['), _c(']'), _c(r'\', flex: 15)],
      [
        _code('Caps', Scan.caps, flex: 18),
        for (final c in 'asdfghjkl'.split('')) _c(c),
        _c(';'),
        _c("'"),
        _code('⏎', Scan.enter, flex: 22, icon: Icons.keyboard_return),
      ],
      [
        _K('Shift', const _ModKey(Mod.shift), flex: 23, special: true, icon: _caps ? Icons.keyboard_capslock : Icons.arrow_upward),
        for (final c in 'zxcvbnm'.split('')) _c(c),
        _c(','),
        _c('.'),
        _c('/'),
        _K('Shift', const _ModKey(Mod.shift), flex: 27, special: true, icon: _caps ? Icons.keyboard_capslock : Icons.arrow_upward),
      ],
      [_abc, ...left, _K('', const _Char(' '), flex: 60), ...left.reversed, _hide],
    ];
  }

  /// The split keyboard's halves: the phone's rows with a number row,
  /// each cut where half its width falls.
  (List<List<_K>>, List<List<_K>>) get _splitRows {
    final rows = switch (_page) {
      KeyPage.letters => [
        _digits,
        [for (final c in 'qwertyuiop'.split('')) _c(c)],
        [_gap5, for (final c in 'asdfghjkl'.split('')) _c(c), _enter],
        [_shiftKey, for (final c in 'zxcvbnm'.split('')) _c(c), _back],
      ],
      KeyPage.function => _fnRows.take(4).toList(),
      _ => _phoneRows.take(3).toList(),
    };
    final left = <List<_K>>[];
    final right = <List<_K>>[];
    for (final row in rows) {
      final total = row.fold<int>(0, (s, k) => s + k.flex);
      var sum = 0;
      final l = <_K>[];
      final r = <_K>[];
      for (final k in row) {
        // A key goes to the half its middle falls in.
        ((sum + k.flex / 2) * 2 <= total ? l : r).add(k);
        sum += k.flex;
      }
      left.add(l);
      right.add(r);
    }
    if (_page == KeyPage.function) {
      left.add([const _K('ABC', _Go(KeyPage.letters), flex: 15, special: true), _mod(Mod.shift, flex: 15)]);
      right.add([_back, _enter]);
    } else {
      left.add([_abc, _c(','), _K('', const _Char(' '), flex: 30)]);
      right.add([_K('', const _Char(' '), flex: 30), _c('.'), _hide]);
    }
    return (left, right);
  }

  // ---- Drawing ----------------------------------------------------------

  Widget _row(List<_K> row, double height, _Palette p, {bool strip = false}) => SizedBox(
    height: height,
    child: Row(
      children: [
        for (final k in row)
          Expanded(
            flex: k.flex,
            child: k.action is _Gap
                ? const SizedBox()
                : _KeyCap(
                    k: k,
                    palette: p,
                    strip: strip,
                    upper: _caps != _active(Mod.shift),
                    lit: switch (k.action) {
                      _ModKey(:final mod) => _held.contains(mod) || _latch[mod] != _Latch.off,
                      _Go(page: KeyPage.letters) when strip => _page == KeyPage.function,
                      _ => false,
                    },
                    locked: switch (k.action) {
                      _ModKey(mod: Mod.shift) => _caps,
                      _ModKey(:final mod) => _latch[mod] == _Latch.locked,
                      _ => false,
                    },
                    onDown: () => _keyDown(k),
                    onUp: () => _keyUp(k),
                  ),
          ),
      ],
    ),
  );

  Widget _header(_Palette p, bool wide) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(8)),
      child: Text(
        '${widget.target.label} · ${widget.hostOs.label}',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.onChip),
      ),
    );
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: 6),
          chip,
          const Spacer(),
          if (wide && widget.onSplitChanged != null)
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(value: false, label: Text('Full')),
                ButtonSegment(value: true, label: Text('Split')),
              ],
              selected: {widget.split},
              onSelectionChanged: (s) => widget.onSplitChanged!(s.first),
            ),
          IconButton(
            tooltip: 'Hide keyboard',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              releaseAll();
              widget.onHide();
            },
            icon: Icon(Icons.keyboard_arrow_down, color: p.text),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = RemoteKeyboard.isWide(box.maxWidth);
        final split = wide && widget.split;
        final rowHeight = wide && !split ? 50.0 : 46.0;
        final Widget keys;
        if (split) {
          final (left, right) = _splitRows;
          final half = (box.maxWidth * 0.36).clamp(0.0, 372.0);
          Widget column(List<List<_K>> rows) => SizedBox(
            width: half,
            child: Column(mainAxisSize: MainAxisSize.min, children: [for (final r in rows) _row(r, rowHeight, p)]),
          );
          keys = Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              column(left),
              Expanded(child: _TouchpadArea(pad: widget.touchpad, palette: p, height: rowHeight * left.length)),
              column(right),
            ],
          );
        } else {
          final rows = wide ? _fullRows : _phoneRows;
          keys = Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(mainAxisSize: MainAxisSize.min, children: [for (final r in rows) _row(r, rowHeight, p)]),
            ),
          );
        }
        return ColoredBox(
          color: p.background,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(3, 0, 3, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(p, wide),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: wide && !split ? 1100 : double.infinity),
                      child: _row(_strip, 40, p, strip: true),
                    ),
                  ),
                  keys,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The split keyboard's middle: drags move the pointer, a tap clicks, two
/// fingers scroll; Left and Right buttons below.
class _TouchpadArea extends StatefulWidget {
  const _TouchpadArea({required this.pad, required this.palette, required this.height});
  final Touchpad? pad;
  final _Palette palette;
  final double height;

  @override
  State<_TouchpadArea> createState() => _TouchpadAreaState();
}

class _TouchpadAreaState extends State<_TouchpadArea> {
  int _fingers = 0;
  Offset? _last;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final pad = widget.pad;
    Widget button(String label, int b) => Expanded(
      child: Listener(
        onPointerDown: (_) {
          HapticFeedback.selectionClick();
          pad?.button(b, true);
        },
        onPointerUp: (_) => pad?.button(b, false),
        onPointerCancel: (_) => pad?.button(b, false),
        child: Container(
          margin: const EdgeInsets.all(3),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.special, borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: TextStyle(color: p.text, fontSize: 13, fontWeight: FontWeight.w500)),
        ),
      ),
    );
    return SizedBox(
      height: widget.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Column(
          children: [
            Expanded(
              child: Listener(
                onPointerDown: (e) {
                  _fingers++;
                  _last = e.position;
                },
                onPointerUp: (_) => _fingers = (_fingers - 1).clamp(0, 10),
                onPointerCancel: (_) => _fingers = (_fingers - 1).clamp(0, 10),
                onPointerMove: (e) {
                  final last = _last;
                  _last = e.position;
                  if (last == null) return;
                  final d = e.position - last;
                  if (_fingers >= 2) {
                    pad?.scroll(d / _fingers.toDouble());
                  } else {
                    pad?.move(d);
                  }
                },
                child: GestureDetector(
                  onTap: () {
                    pad?.button(0, true);
                    pad?.button(0, false);
                  },
                  child: CustomPaint(
                    painter: _DashedBox(p.outline),
                    child: Center(
                      child: Text('Touchpad', style: TextStyle(color: p.text.withValues(alpha: 0.6), fontSize: 13)),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 44, child: Row(children: [button('Left', 0), button('Right', 1)])),
          ],
        ),
      ),
    );
  }
}

class _DashedBox extends CustomPainter {
  _DashedBox(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.color != color;
}

/// The keyboard's colours: Material 3 tones of the app's scheme.
final class _Palette {
  _Palette(ColorScheme cs)
    : background = cs.surfaceContainer,
      key = cs.surfaceContainerHighest,
      special = cs.secondaryContainer,
      strip = cs.surfaceContainerHigh,
      text = cs.onSurface,
      accent = cs.primary,
      onAccent = cs.onPrimary,
      pressed = cs.outlineVariant,
      chip = cs.primaryContainer,
      onChip = cs.onPrimaryContainer,
      outline = cs.outline;

  final Color background, key, special, strip, text, accent, onAccent, pressed, chip, onChip, outline;
}

class _KeyCap extends StatefulWidget {
  const _KeyCap({
    required this.k,
    required this.palette,
    required this.strip,
    required this.upper,
    required this.lit,
    required this.locked,
    required this.onDown,
    required this.onUp,
  });

  final _K k;
  final _Palette palette;
  final bool strip, upper, lit, locked;
  final VoidCallback onDown, onUp;

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
  bool _pressed = false;
  OverlayEntry? _preview;

  void _down() {
    setState(() => _pressed = true);
    widget.onDown();
    final k = widget.k;
    if (k.action is _Char && k.label.trim().isNotEmpty) _showPreview();
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    _preview?.remove();
    _preview = null;
    widget.onUp();
  }

  /// Gboard's key preview: the character in a bubble over the finger.
  void _showPreview() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context);
    if (box == null || overlay == null) return;
    final at = box.localToGlobal(Offset.zero);
    final size = box.size;
    final p = widget.palette;
    final label = widget.upper ? widget.k.label.toUpperCase() : widget.k.label;
    _preview = OverlayEntry(
      builder: (_) => Positioned(
        left: at.dx - 4,
        top: at.dy - size.height - 8,
        width: size.width + 8,
        height: size.height + 4,
        child: IgnorePointer(
          child: Material(
            elevation: 4,
            color: p.key,
            borderRadius: BorderRadius.circular(12),
            child: Center(child: Text(label, style: TextStyle(fontSize: 26, color: p.text))),
          ),
        ),
      ),
    );
    overlay.insert(_preview!);
  }

  @override
  void dispose() {
    _preview?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final k = widget.k;
    final enter = k.action is _Code && (k.action as _Code).code == Scan.enter;
    final Color bg;
    final Color fg;
    if (widget.lit || enter) {
      bg = p.accent;
      fg = p.onAccent;
    } else if (_pressed) {
      bg = p.pressed;
      fg = p.text;
    } else {
      bg = widget.strip ? p.strip : (k.special ? p.special : p.key);
      fg = p.text;
    }
    final label = k.action is _Char && widget.upper ? k.label.toUpperCase() : k.label;
    final Widget face = k.icon != null
        ? Icon(k.icon, size: widget.strip ? 18 : 20, color: fg)
        : Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              fontSize: k.action is _Char && label.length == 1 ? 21 : 13,
              fontWeight: k.special ? FontWeight.w500 : FontWeight.w400,
              color: fg,
            ),
          );
    return Semantics(
      button: true,
      label: k.label.isEmpty ? (k.action is _Char ? 'Space' : null) : k.label,
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 3),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 60),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(enter ? 24 : 12)),
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                FittedBox(fit: BoxFit.scaleDown, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: face)),
                if (widget.locked) Positioned(bottom: 4, child: Container(width: 14, height: 2, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
