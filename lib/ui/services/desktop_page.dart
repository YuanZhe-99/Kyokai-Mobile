// A device's Remote Desktop or VNC: its picture with the viewer's fingers
// (trackpad or touch), the on-screen keyboard (RDP takes scan codes, VNC
// keysyms), and the clipboard both ways.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/native.dart';
import '../../data/app_state.dart';
import '../../data/prefs.dart';
import '../../data/services.dart';
import '../keyboard/hardware_keys.dart';
import '../keyboard/keyboard.dart';
import '../keyboard/keys.dart';
import '../shell/app.dart';
import '../viewer/session_sheets.dart' show typeTextInto;
import '../viewer/surface.dart';
import 'terminal_page.dart';

class DesktopPage extends StatefulWidget {
  const DesktopPage({super.key, required this.session});
  final ServiceSession session;

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage> with WidgetsBindingObserver implements PointerSink {
  final _viewport = RemoteViewport();
  final _focus = FocusNode(debugLabel: 'desktop');
  final _hw = HardwareKeys();
  bool _keyboard = false;
  bool _wasConnected = false;

  // The pointer as the host knows it: where, and the buttons held (1 left,
  // 2 middle, 4 right).
  int _x = 0, _y = 0, _buttons = 0;
  bool _shift = false;

  ServiceSession get s => widget.session;
  bool get _vnc => s.kind == ServiceKind.vnc;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    WidgetsBinding.instance.removeObserver(this);
    _hw.releaseAll(_send);
    _focus.dispose();
    _viewport.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    if (s.width > 0) _viewport.layout(_viewport.view, Size(s.width.toDouble(), s.height.toDouble()));
    if (s.connected && !_wasConnected) unawaited(_offerClipboard());
    _wasConnected = s.connected;
    setState(() {});
  }

  /// What the phone copied goes to the host when the page comes to the front.
  Future<void> _offerClipboard() async {
    final t = await Native.clipboardText();
    if (t != null && t.isNotEmpty && t != s.hostClipboard) s.clipboard(t);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && s.connected) unawaited(_offerClipboard());
  }

  // ---- PointerSink: picture fractions to the host's pixels ------------------

  void _at(double x, double y) {
    _x = (x * s.width).round().clamp(0, s.width > 0 ? s.width - 1 : 0);
    _y = (y * s.height).round().clamp(0, s.height > 0 ? s.height - 1 : 0);
  }

  @override
  void move(double x, double y) {
    _at(x, y);
    s.pointer(_x, _y, _buttons);
  }

  @override
  void button(int button, bool down, double x, double y) {
    _at(x, y);
    final bit = switch (button) {
      0 => 1,
      1 => 4,
      _ => 2,
    };
    _buttons = down ? _buttons | bit : _buttons & ~bit;
    s.pointer(_x, _y, _buttons);
  }

  @override
  void scroll(double dx, double dy) => s.scroll(_x, _y, dx, dy);

  // ---- The split keyboard's touchpad drives the cursor ---------------------

  void _padMove(Offset d) {
    final shown = _viewport.shown;
    if (shown.isEmpty) return;
    final k = 1.5 * AppScope.of(context).prefs.pointerSpeed / 1.6;
    final c = _viewport.cursor + Offset(d.dx * k / shown.width, d.dy * k / shown.height);
    _viewport.cursor = Offset(c.dx.clamp(0.0, 1.0), c.dy.clamp(0.0, 1.0));
    move(_viewport.cursor.dx, _viewport.cursor.dy);
    setState(() {});
  }

  // ---- Keys -----------------------------------------------------------------

  void _send(int code, bool down, {bool caps = false}) {
    if (code == Scan.lshift || code == Scan.rshift) _shift = down;
    if (_vnc) {
      final sym = keysymFor(code, shift: _shift);
      if (sym != 0) s.key(sym, down);
    } else {
      s.scancode(code, down);
    }
  }

  void _ctrlAltDel() {
    for (final c in const [Scan.lctrl, Scan.lalt, Scan.delete]) {
      _send(c, true);
    }
    for (final c in const [Scan.delete, Scan.lalt, Scan.lctrl]) {
      _send(c, false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!s.connected) return KeyEventResult.ignored;
    return _hw.handle(e, _send) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final prefs = AppScope.of(context).prefs;
    _viewport.pinTop = prefs.pictureTop;
    final picture = s.picture;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(s.title),
          actions: [
            IconButton(
              tooltip: prefs.pointerMode == PointerMode.trackpad ? l.pointerTrackpad : l.pointerTouch,
              onPressed: () => setState(
                () => prefs.pointerMode = prefs.pointerMode == PointerMode.trackpad ? PointerMode.touch : PointerMode.trackpad,
              ),
              icon: Icon(prefs.pointerMode == PointerMode.trackpad ? Icons.touch_app_outlined : Icons.back_hand_outlined),
            ),
            IconButton(
              tooltip: l.keyboard,
              isSelected: _keyboard,
              onPressed: () => setState(() => _keyboard = !_keyboard),
              icon: const Icon(Icons.keyboard_outlined),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'text':
                    await typeTextInto(context, s.text);
                  case 'cad':
                    _ctrlAltDel();
                  case 'paste':
                    await _offerClipboard();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'text', child: Text(l.typeText)),
                PopupMenuItem(value: 'paste', child: Text(l.sendClipboard)),
                const PopupMenuItem(value: 'cad', child: Text('Ctrl+Alt+Del')),
              ],
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (picture != null)
                      RemoteSurface(
                        viewport: _viewport,
                        sink: this,
                        mode: prefs.pointerMode,
                        speed: prefs.pointerSpeed,
                        child: RawImage(image: picture, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                      ),
                    if (picture != null) Positioned(top: 10, right: 10, child: Minimap(viewport: _viewport)),
                    if (!s.connected || picture == null)
                      s.connected
                          ? Center(child: Text(l.waitingForPicture, style: TextStyle(color: cs.onInverseSurface)))
                          : ServiceStateCard(session: s),
                  ],
                ),
              ),
              if (_keyboard && s.connected)
                RemoteKeyboard(
                  send: _send,
                  hostOs: _vnc ? HostOs.macos : HostOs.windows,
                  target: _vnc ? KeyTarget.vnc : KeyTarget.rdp,
                  split: prefs.splitKeyboard,
                  onSplitChanged: (v) => prefs.splitKeyboard = v,
                  touchpad: _PadBridge(this),
                  onSpecial: (action) {
                    if (action != 'ctrl_alt_del') return false;
                    _ctrlAltDel();
                    return true;
                  },
                  onHide: () => setState(() => _keyboard = false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The split keyboard's touchpad, as the page's cursor.
class _PadBridge implements KeyboardPad {
  _PadBridge(this.p);
  final _DesktopPageState p;

  @override
  void move(Offset delta) => p._padMove(delta);

  @override
  void button(int button, bool down) {
    final c = p._viewport.cursor;
    p.button(button, down, c.dx, c.dy);
  }

  @override
  void scroll(Offset notches) => p.scroll(notches.dx, notches.dy);
}
