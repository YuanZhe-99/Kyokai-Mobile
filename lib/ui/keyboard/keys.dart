// Key codes shared by the on-screen keyboard and the protocols it drives.
//
// The keyboard speaks set-1 scan codes, as Windows numbers them (0xE0xx for
// extended keys): the keys go by their place, as Kyokai's Map mode sends
// them, and RDP takes the same codes. VNC wants X11 keysyms instead, which
// [keysymFor] derives from the code and Shift.

/// Set-1 scan codes.
abstract final class Scan {
  static const esc = 0x01, backspace = 0x0E, tab = 0x0F, enter = 0x1C, lctrl = 0x1D;
  static const lshift = 0x2A, rshift = 0x36, lalt = 0x38, space = 0x39, caps = 0x3A;
  static const f1 = 0x3B, f11 = 0x57, f12 = 0x58, numLock = 0x45, scrollLock = 0x46;
  static const rctrl = 0xE01D, ralt = 0xE038, lwin = 0xE05B, rwin = 0xE05C, menu = 0xE05D;
  static const home = 0xE047, up = 0xE048, pageUp = 0xE049, left = 0xE04B, right = 0xE04D;
  static const end = 0xE04F, down = 0xE050, pageDown = 0xE051, insert = 0xE052, delete = 0xE053;
  static const printScreen = 0xE037, pause = 0xE11D;

  /// F1–F12.
  static int f(int n) => n <= 10 ? f1 + n - 1 : (n == 11 ? f11 : f12);

  static bool isModifier(int code) => const {
    lctrl, rctrl, lshift, rshift, lalt, ralt, lwin, rwin,
  }.contains(code);
}

/// The key that types a character on a US keyboard: its scan code and
/// whether Shift goes with it.
const Map<String, (int, bool)> usKeys = {
  '1': (0x02, false), '2': (0x03, false), '3': (0x04, false), '4': (0x05, false),
  '5': (0x06, false), '6': (0x07, false), '7': (0x08, false), '8': (0x09, false),
  '9': (0x0A, false), '0': (0x0B, false), '-': (0x0C, false), '=': (0x0D, false),
  '!': (0x02, true), '@': (0x03, true), '#': (0x04, true), r'$': (0x05, true),
  '%': (0x06, true), '^': (0x07, true), '&': (0x08, true), '*': (0x09, true),
  '(': (0x0A, true), ')': (0x0B, true), '_': (0x0C, true), '+': (0x0D, true),
  'q': (0x10, false), 'w': (0x11, false), 'e': (0x12, false), 'r': (0x13, false),
  't': (0x14, false), 'y': (0x15, false), 'u': (0x16, false), 'i': (0x17, false),
  'o': (0x18, false), 'p': (0x19, false), '[': (0x1A, false), ']': (0x1B, false),
  '{': (0x1A, true), '}': (0x1B, true),
  'a': (0x1E, false), 's': (0x1F, false), 'd': (0x20, false), 'f': (0x21, false),
  'g': (0x22, false), 'h': (0x23, false), 'j': (0x24, false), 'k': (0x25, false),
  'l': (0x26, false), ';': (0x27, false), "'": (0x28, false), '`': (0x29, false),
  ':': (0x27, true), '"': (0x28, true), '~': (0x29, true), r'\': (0x2B, false), '|': (0x2B, true),
  'z': (0x2C, false), 'x': (0x2D, false), 'c': (0x2E, false), 'v': (0x2F, false),
  'b': (0x30, false), 'n': (0x31, false), 'm': (0x32, false), ',': (0x33, false),
  '.': (0x34, false), '/': (0x35, false), '<': (0x33, true), '>': (0x34, true), '?': (0x35, true),
  ' ': (Scan.space, false),
};

/// The character a US key types, without and with Shift.
final Map<int, (String, String)> _usChars = () {
  final m = <int, (String, String)>{};
  final plain = <int, String>{};
  final shifted = <int, String>{};
  for (final e in usKeys.entries) {
    final (code, shift) = e.value;
    (shift ? shifted : plain)[code] = e.key;
  }
  for (final code in plain.keys) {
    final p = plain[code]!;
    m[code] = (p, shifted[code] ?? (p.length == 1 && p.toUpperCase() != p ? p.toUpperCase() : p));
  }
  return m;
}();

/// X11 keysyms of the named keys.
const Map<int, int> _namedKeysyms = {
  Scan.esc: 0xFF1B, Scan.backspace: 0xFF08, Scan.tab: 0xFF09, Scan.enter: 0xFF0D,
  Scan.lctrl: 0xFFE3, Scan.rctrl: 0xFFE4, Scan.lshift: 0xFFE1, Scan.rshift: 0xFFE2,
  Scan.lalt: 0xFFE9, Scan.ralt: 0xFFEA, Scan.lwin: 0xFFEB, Scan.rwin: 0xFFEC,
  Scan.menu: 0xFF67, Scan.caps: 0xFFE5, Scan.numLock: 0xFF7F, Scan.scrollLock: 0xFF14,
  Scan.home: 0xFF50, Scan.left: 0xFF51, Scan.up: 0xFF52, Scan.right: 0xFF53,
  Scan.down: 0xFF54, Scan.pageUp: 0xFF55, Scan.pageDown: 0xFF56, Scan.end: 0xFF57,
  Scan.insert: 0xFF63, Scan.delete: 0xFFFF, Scan.printScreen: 0xFF61, Scan.pause: 0xFF13,
  Scan.space: 0x0020,
};

/// The X11 keysym VNC sends for a key: the character it types (with Shift
/// as held) for a printable key, the named keysym otherwise; 0 when none.
int keysymFor(int code, {required bool shift}) {
  if (code >= Scan.f1 && code < Scan.f1 + 10) return 0xFFBE + code - Scan.f1;
  if (code == Scan.f11) return 0xFFC8;
  if (code == Scan.f12) return 0xFFC9;
  final named = _namedKeysyms[code];
  if (named != null) return named;
  final chars = _usChars[code];
  if (chars == null) return 0;
  // Latin-1 keysyms are the character's code point.
  return (shift ? chars.$2 : chars.$1).codeUnitAt(0);
}

/// The host's system: names and orders the modifier keys and picks the
/// shortcuts on the Fn page. The keys themselves go by place either way.
enum HostOs {
  windows,
  macos,
  linux;

  static HostOs parse(Object? os) {
    final s = '${os ?? ''}'.toLowerCase();
    if (s.contains('mac') || s.contains('darwin') || s.contains('os x')) return macos;
    if (s.contains('linux') || s.contains('ubuntu') || s.contains('debian') || s.contains('fedora')) {
      return linux;
    }
    return windows;
  }

  String get label => switch (this) {
    windows => 'Windows',
    macos => 'macOS',
    linux => 'Linux',
  };
}

/// What the keyboard drives: names the chip over the keys.
enum KeyTarget {
  kyokai,
  rdp,
  vnc;

  String get label => switch (this) {
    kyokai => 'Kyokai · Map',
    rdp => 'Remote Desktop',
    vnc => 'VNC',
  };
}
