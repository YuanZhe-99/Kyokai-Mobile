// A host's screen: the picture with the fingers on it, the on-screen
// keyboard docked under it, and the session's controls. Portrait phones get
// a header, mouse buttons and the minimap; landscape phones a floating
// toolbar over a full picture; wide screens a header, the keyboard (full or
// split) and the host's AI beside the picture.

import 'dart:async';
import 'dart:math' as math;


import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../../core/native.dart';
import '../../data/app_state.dart';
import '../../data/model.dart';
import '../../data/prefs.dart';
import '../../data/sessions.dart';
import '../ai/ai_panel.dart';
import '../home/device_widgets.dart';
import '../keyboard/hardware_keys.dart';
import '../keyboard/keyboard.dart';
import '../keyboard/keys.dart';
import '../shell/app.dart';
import 'session_sheets.dart';
import 'posture.dart';
import 'surface.dart';
import 'touchpad.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.session});
  final RemoteSession session;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> implements PointerSink {
  final _viewport = RemoteViewport();
  final _keyboardKey = GlobalKey<RemoteKeyboardState>();
  final _focus = FocusNode(debugLabel: 'viewer');
  bool _keyboard = false;
  bool _ai = false;
  bool _toolbar = true;
  Timer? _moveTimer;
  Offset? _pendingMove;
  bool _promptedPassword = false;
  final _hw = HardwareKeys();

  RemoteSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    // Laptop mode also reads the hinge's angle (posture.dart).
    unawaited(Native.watchHinge(true));
    Native.hingeAngle.addListener(_onHinge);
    s.addListener(_onSession);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    Native.hingeAngle.removeListener(_onHinge);
    unawaited(Native.watchHinge(false));
    _moveTimer?.cancel();
    _keyboardKey.currentState?.releaseAll();
    _hw.releaseAll(s.scan);
    _focus.dispose();
    _viewport.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final size = s.pictureSize;
    if (!size.isEmpty) _viewport.layout(_viewport.view, size);
    // The host's own pointer moves (it or its user moved it): follow it.
    final c = s.cursor;
    if (c != null && s.cursorVisible && !_fingerDown) _viewport.cursor = c;
    if (!_promptedPassword && (s.state == 'failed' && s.failure == 'password')) {
      _promptedPassword = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _askPassword());
    }
    setState(() {});
  }

  bool _fingerDown = false;

  /// Whether the keyboard was considered on entry (once a page).
  bool _keyboardDecided = false;

  /// On entry only: the keyboard opens by itself when the room under the
  /// picture holds it, so it costs no picture.
  void _maybeShowKeyboard() {
    if (_keyboardDecided || _keyboard) return;
    if (s.pictureSize.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _keyboardDecided || _viewport.view.isEmpty) return;
      _keyboardDecided = true;
      final width = MediaQuery.sizeOf(context).width;
      final kb = RemoteKeyboard.heightFor(width, split: AppScope.of(context).prefs.splitKeyboard);
      if (_viewport.roomBelow(kb)) setState(() => _keyboard = true);
    });
  }

  // The layout follows the hinge only where the angle crosses laptop posture.
  bool? _halfOpen;
  void _onHinge() {
    final a = Native.hingeAngle.value;
    final half = a != null && a >= 30 && a <= 150;
    if (half == _halfOpen) return;
    _halfOpen = half;
    if (mounted) setState(() {});
  }

  Future<void> _askPassword() async {
    final r = await askPassword(context, s);
    if (r == null) return;
    _promptedPassword = false;
    await s.retry(r.$1, remember: r.$2);
  }

  // ---- PointerSink: moves coalesced to one per 8 ms -------------------------

  @override
  void move(double x, double y) {
    _pendingMove = Offset(x, y);
    _moveTimer ??= Timer(const Duration(milliseconds: 8), _flushMove);
  }

  void _flushMove() {
    _moveTimer = null;
    final p = _pendingMove;
    _pendingMove = null;
    if (p != null) s.pointer('move', p.dx, p.dy);
  }

  @override
  void button(int button, bool down, double x, double y) {
    _flushMove();
    _fingerDown = down;
    s.pointer(down ? 'down' : 'up', x, y, button: button);
  }

  @override
  void scroll(double dx, double dy) => s.scroll(dx.clamp(-100, 100), dy.clamp(-100, 100));

  // ---- Touchpad of the split keyboard --------------------------------------

  KeyboardPad get _pad => _TouchpadBridge(this);

  void _padMove(Offset d) {
    final prefs = AppScope.of(context).prefs;
    final shown = _viewport.shown;
    if (shown.isEmpty) return;
    // The pad is small: it reaches 1.5 times as far as the screen's own
    // trackpad, at the user's pointer speed (1.6 being the default).
    final k = 1.5 * prefs.pointerSpeed / 1.6;
    final c = _viewport.cursor + Offset(d.dx * k / shown.width, d.dy * k / shown.height);
    _viewport.cursor = Offset(c.dx.clamp(0.0, 1.0), c.dy.clamp(0.0, 1.0));
    move(_viewport.cursor.dx, _viewport.cursor.dy);
    setState(() {});
  }

  void scrollPad(Offset notches) => scroll(notches.dx, notches.dy);

  // ---- Keys ------------------------------------------------------------------

  void _sendScan(int code, bool down, {required bool caps}) {
    // A Mac host: Ctrl on the phone is Ctrl there too; the keyboard names
    // Command itself, so no swap.
    s.scan(code, down, caps: caps);
  }

  bool _special(String action) {
    if (action == 'ctrl_alt_del' && s.actions['ctrl_alt_del'] == true) {
      s.action('ctrl-alt-del');
      return true;
    }
    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!s.mayControl) return KeyEventResult.ignored;
    return _hw.handle(e, s.scan) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // ---- Building --------------------------------------------------------------

  HostOs get _os => s.peer.os.isEmpty && s.peer.name.isEmpty ? HostOs.windows : s.peer.hostOs;

  String _statsLine() {
    final l = context.l;
    final st = s.stats;
    final parts = <String>[];
    final status = AppScope.of(context).engine.status;
    final reach = reachText(l, status, s.deviceId);
    final route = AppScope.of(context).engine.status.session(s.id ?? -1)?.route;
    if (route != null && route.isNotEmpty) {
      parts.add(route);
    } else if (reach != null) {
      parts.add(reach);
    }
    final codec = s.videoStart['codec'];
    if (codec != null && codec != 'raw-rgba') parts.add('$codec'.toUpperCase());
    if (st['fps'] != null) parts.add('${st['frames'] ?? st['fps']} fps');
    if (st['delay_ms'] != null) parts.add('${st['delay_ms']} ms');
    return parts.join(' · ');
  }

  Widget _picture() {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final t = s.texture;
    if (t != null) {
      return ColoredBox(
        color: Colors.black,
        child: t.view
            ? _VideoView(key: ValueKey(t.id), video: t.id)
            : Texture(textureId: t.id, filterQuality: FilterQuality.medium),
      );
    }
    if (s.rawImage != null) return RawImage(image: s.rawImage, fit: BoxFit.fill);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Text(
          s.unsupported ? l.videoUnsupported('${s.videoStart['codec']}') : l.waitingForPicture,
          style: TextStyle(color: cs.onInverseSurface),
        ),
      ),
    );
  }

  /// Dialing, waiting for the host's user, refused, ended.
  Widget? _stateOverlay() {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    Widget card(List<Widget> children) => Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
    switch (s.state) {
      case 'connecting':
        return card([const CircularProgressIndicator(), const SizedBox(height: 16), Text(l.connecting)]);
      case 'confirming':
        return card([
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l.confirmingOnHost, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: _askPassword, icon: const Icon(Icons.password), label: Text(l.typePassword)),
        ]);
      case 'reconnecting':
        return Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(20)),
            child: Text(l.reconnecting, style: TextStyle(color: cs.onInverseSurface)),
          ),
        );
      case 'failed' || 'closed':
        return card([
          Icon(s.state == 'failed' ? Icons.error_outline : Icons.link_off, size: 40, color: cs.error),
          const SizedBox(height: 12),
          Text(
            s.state == 'closed' ? l.sessionEnded : (s.dialError ?? failureText(l, s.failure)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              if (s.failure == 'password' || s.failure == 'denied' || s.failure == 'absent' || s.failure == 'timeout')
                FilledButton.icon(
                  onPressed: _askPassword,
                  icon: const Icon(Icons.password),
                  label: Text(l.typePassword),
                ),
              OutlinedButton(onPressed: () => s.retry(''), child: Text(l.tryAgain)),
            ],
          ),
        ]);
    }
    if (s.connected && !s.granted.contains('view-screen')) {
      return card([Text(l.noViewPermission)]);
    }
    return null;
  }

  Widget _surface({bool showButtons = true}) {
    final prefs = AppScope.of(context).prefs;
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final overlay = _stateOverlay();
    // Fills what it is given: inside a Row the height is only a limit, and a
    // Stack would take the size of its unpositioned children (none, or the
    // zoom chip's empty box), leaving the picture 0 px tall.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: RemoteSurface(
              viewport: _viewport,
              sink: this,
              mode: prefs.pointerMode,
              speed: prefs.pointerSpeed,
              child: _picture(),
            ),
          ),
        ),
        Positioned(top: 10, right: 10, child: Minimap(viewport: _viewport)),
        ListenableBuilder(
          listenable: _viewport,
          builder: (context, _) => _viewport.scale > 1.01
              ? Positioned(
                  top: 12,
                  left: 10,
                  child: GestureDetector(
                    onTap: _viewport.reset,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: cs.surface.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_viewport.scale.toStringAsFixed(1)}×',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (s.inputPaused && s.connected)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Chip(label: Text(l.inputPaused), avatar: const Icon(Icons.pause_circle_outline, size: 18)),
            ),
          ),
        if (prefs.overlay)
          Positioned(
            left: 8,
            bottom: showButtons ? 64 : 8,
            child: _DebugOverlay(session: s),
          ),
        if (showButtons && s.connected && prefs.pointerMode == PointerMode.trackpad)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: _MouseButtons(sink: this, viewport: _viewport),
            ),
          ),
        ?overlay,
      ],
    );
  }

  Widget _headerActions({required bool compact}) {
    final l = context.l;
    final prefs = AppScope.of(context).prefs;
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SegmentedButton<PointerMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(value: PointerMode.trackpad, label: Text(l.pointerTrackpad)),
                ButtonSegment(value: PointerMode.touch, label: Text(l.pointerTouch)),
              ],
              selected: {prefs.pointerMode},
              onSelectionChanged: (v) => setState(() => prefs.pointerMode = v.first),
            ),
          )
        else
          IconButton(
            tooltip: prefs.pointerMode == PointerMode.trackpad ? l.pointerTrackpad : l.pointerTouch,
            onPressed: () => setState(
              () => prefs.pointerMode = prefs.pointerMode == PointerMode.trackpad
                  ? PointerMode.touch
                  : PointerMode.trackpad,
            ),
            icon: Icon(prefs.pointerMode == PointerMode.trackpad ? Icons.touch_app_outlined : Icons.back_hand_outlined),
          ),
        if (s.displays.length > 1)
          IconButton(
            tooltip: l.displays,
            onPressed: () => showDisplays(context, s),
            icon: Badge(label: Text('${s.display + 1}'), child: const Icon(Icons.monitor_outlined)),
          ),
        IconButton.filledTonal(
          tooltip: l.keyboard,
          isSelected: _keyboard,
          onPressed: s.mayControl ? () => setState(() => _keyboard = !_keyboard) : null,
          icon: const Icon(Icons.keyboard_outlined),
        ),
        if (!compact)
          IconButton(tooltip: l.quality, onPressed: () => showQuality(context, s), icon: const Icon(Icons.tune)),
        if (!compact)
          IconButton(
            tooltip: l.aiTask,
            isSelected: _ai,
            onPressed: () => setState(() => _ai = !_ai),
            icon: Icon(Icons.auto_awesome_outlined, color: _ai ? cs.primary : null),
          ),
        IconButton(tooltip: l.more, onPressed: _more, icon: const Icon(Icons.more_vert)),
      ],
    );
  }

  void _more() => showSessionMenu(
    context,
    s,
    onQuality: () => showQuality(context, s),
    onAi: () => _openAiSheet(),
    onTypeText: () => typeText(context, s),
    onDisconnect: () async {
      await s.close();
      if (mounted) Navigator.of(context).pop();
    },
  );

  void _openAiSheet() {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      setState(() => _ai = true);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.75, child: AiPanel(deviceId: s.deviceId)),
    );
  }

  Widget _keyboardWidget() => ListenableBuilder(
    listenable: AppScope.of(context).prefs,
    builder: (context, _) {
      final prefs = AppScope.of(context).prefs;
      return RemoteKeyboard(
        key: _keyboardKey,
        send: _sendScan,
        hostOs: _os,
        target: KeyTarget.kyokai,
        split: prefs.splitKeyboard,
        onSplitChanged: (v) => prefs.splitKeyboard = v,
        touchpad: _pad,
        onSpecial: _special,
        onHide: () => setState(() => _keyboard = false),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 600 && size.height >= 480;
    _viewport.pinTop = AppScope.of(context).prefs.pictureTop;
    final landscapePhone = !wide && size.width > size.height;
    return PopScope(
      canPop: true,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: switch (_laptopHinge()) {
          final hinge? => _laptop(hinge),
          null => landscapePhone ? _landscape() : _standard(wide),
        },
      ),
    );
  }

  Widget _standard(bool wide) {
    final cs = Theme.of(context).colorScheme;
    _maybeShowKeyboard();
    final showAiPanel = wide && _ai && MediaQuery.sizeOf(context).width >= 840;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.title, style: Theme.of(context).textTheme.titleMedium),
            Text(
              _statsLine(),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          _headerActions(compact: !wide),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _surface(showButtons: !_keyboard || wide)),
                  if (showAiPanel)
                    SizedBox(
                      width: 360,
                      child: Material(
                        color: cs.surfaceContainerLow,
                        child: AiPanel(deviceId: s.deviceId, onClose: () => setState(() => _ai = false)),
                      ),
                    ),
                ],
              ),
            ),
            if (_keyboard) _keyboardWidget(),
          ],
        ),
      ),
    );
  }

  /// The hinge across a half-open foldable (laptop posture), when laptop
  /// mode is on.
  Rect? _laptopHinge() {
    if (!AppScope.of(context).prefs.laptopMode) return null;
    return laptopHinge(context, angle: Native.hingeAngle.value)?.$1;
  }

  /// Laptop posture: the picture above the hinge with the floating toolbar;
  /// below it the full keyboard and a touchpad filling what is left.
  Widget _laptop(Rect hinge) {
    final cs = Theme.of(context).colorScheme;
    // Room for the status bar above the picture and the navigation bar
    // under the keyboard, unless the person chose the whole screen.
    final safe = AppScope.of(context).prefs.laptopSafeArea;
    final top = safe ? MediaQuery.paddingOf(context).top : 0.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          SizedBox(height: top),
          SizedBox(
            height: math.max(0, hinge.top - top),
            child: MediaQuery.removePadding(
              context: context,
              removeTop: safe,
              child: Stack(
                children: [
                  Positioned.fill(child: _surface(showButtons: false)),
                  _floatingBar(),
                ],
              ),
            ),
          ),
          SizedBox(height: hinge.height),
          Expanded(
            child: Material(
              color: cs.surfaceContainer,
              child: SafeArea(
                top: false,
                bottom: safe,
                child: Column(
                  children: [
                    RemoteKeyboard(
                      key: _keyboardKey,
                      send: _sendScan,
                      hostOs: _os,
                      target: KeyTarget.kyokai,
                      split: false,
                      onSplitChanged: (_) {},
                      onSpecial: _special,
                      onHide: () {},
                    ),
                    Expanded(child: _LaptopPad(pad: _pad)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _landscape() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _surface(showButtons: false)),
                _floatingBar(),
              ],
            ),
          ),
          if (_keyboard) _keyboardWidget(),
        ],
      ),
    );
  }

  /// The toolbar floating over a full picture, folded away to a handle.
  Widget _floatingBar() {
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _toolbar
                ? Material(
                    key: const ValueKey('bar'),
                    color: cs.surfaceContainerHigh.withValues(alpha: 0.95),
                    shape: const StadiumBorder(),
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          _headerActions(compact: true),
                          IconButton(
                            onPressed: () => setState(() => _toolbar = false),
                            icon: const Icon(Icons.expand_less),
                          ),
                        ],
                      ),
                    ),
                  )
                : IconButton.filledTonal(
                    key: const ValueKey('pull'),
                    onPressed: () => setState(() => _toolbar = true),
                    icon: const Icon(Icons.expand_more),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Laptop mode's touchpad under the keyboard, with Left and Right below it.
class _LaptopPad extends StatefulWidget {
  const _LaptopPad({required this.pad});
  final KeyboardPad pad;

  @override
  State<_LaptopPad> createState() => _LaptopPadState();
}

class _LaptopPadState extends State<_LaptopPad> implements TouchpadSink {
  late final _engine = Touchpad(this);

  @override
  void move(Offset delta) => widget.pad.move(delta);

  @override
  void button(int button, bool down) {
    if (down) HapticFeedback.selectionClick();
    widget.pad.button(button, down);
  }

  @override
  void scroll(Offset notches) => widget.pad.scroll(notches);

  @override
  void pinch(double scale, Offset focal, Offset pan) {}

  @override
  void dispose() {
    _engine.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      // Too little room under the keys: no pad (the keyboard still works).
      builder: (context, box) => box.maxHeight < 96 ? const SizedBox.shrink() : _pad(context),
    );
  }

  Widget _pad(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = context.l;
    Widget key(String label, int b) => Expanded(
      child: Listener(
        onPointerDown: (_) => button(b, true),
        onPointerUp: (_) => button(b, false),
        onPointerCancel: (_) => button(b, false),
        child: Container(
          margin: const EdgeInsets.all(3),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
          child: Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ),
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Column(
            children: [
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _engine.down(e.pointer, e.localPosition, e.timeStamp),
                  onPointerMove: (e) => _engine.move(e.pointer, e.localPosition, e.timeStamp),
                  onPointerUp: (e) => _engine.up(e.pointer, e.timeStamp),
                  onPointerCancel: (e) => _engine.cancel(e.pointer),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              SizedBox(height: 36, child: Row(children: [key(l.mouseLeft, 0), key(l.mouseRight, 1)])),
            ],
          ),
        ),
      ),
    );
  }
}

/// The split keyboard's touchpad drives the trackpad cursor.
class _TouchpadBridge implements KeyboardPad {
  _TouchpadBridge(this.v);
  final _ViewerPageState v;

  @override
  void move(Offset delta) => v._padMove(delta);

  @override
  void button(int button, bool down) {
    final c = v._viewport.cursor;
    v.button(button, down, c.dx, c.dy);
  }

  @override
  void scroll(Offset delta) => v.scrollPad(delta);
}

/// Left, Right and a scroll strip, under the picture in trackpad mode.
class _MouseButtons extends StatefulWidget {
  const _MouseButtons({required this.sink, required this.viewport});
  final PointerSink sink;
  final RemoteViewport viewport;

  @override
  State<_MouseButtons> createState() => _MouseButtonsState();
}

class _MouseButtonsState extends State<_MouseButtons> {
  double _rest = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    Widget button(String label, int b) => Listener(
      onPointerDown: (_) {
        HapticFeedback.selectionClick();
        final c = widget.viewport.cursor;
        widget.sink.button(b, true, c.dx, c.dy);
      },
      onPointerUp: (_) {
        final c = widget.viewport.cursor;
        widget.sink.button(b, false, c.dx, c.dy);
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(l.mouseLeft, 0),
          const SizedBox(width: 6),
          button(l.mouseRight, 1),
          const SizedBox(width: 6),
          GestureDetector(
            onVerticalDragUpdate: (d) {
              _rest += d.delta.dy / 16;
              final lines = _rest.truncateToDouble();
              if (lines != 0) {
                widget.sink.scroll(0, lines);
                _rest -= lines;
              }
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
              child: Tooltip(message: l.scroll, child: const Icon(Icons.unfold_more, size: 20)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Decoder, size, frame rate and delay over the picture (Settings ›
/// Diagnostics › Show video details), for testing on a device.
class _DebugOverlay extends StatefulWidget {
  const _DebugOverlay({required this.session});
  final RemoteSession session;

  @override
  State<_DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<_DebugOverlay> {
  // The decoder's own counts, asked for once a second.
  Map<String, Object?>? _info;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final t = widget.session.texture;
      final info = t == null ? null : await Native.videoInfo(t.id);
      if (mounted) setState(() => _info = info);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final i = _info;
    final st = s.stats;
    final t = s.texture;
    final lines = [
      '${s.videoStart['codec'] ?? '-'} ${s.pictureSize.width.toInt()}x${s.pictureSize.height.toInt()}'
          '${s.videoStart['placeholder'] != null ? ' (${s.videoStart['placeholder']})' : ''}',
      'host: ${s.videoStart['encoder'] ?? '-'}${s.videoStart['hardware'] == true ? ' hw' : ''}',
      'decoder: ${i?['decoder'] ?? t?.decoder ?? '-'}${(i?['hardware'] ?? t?.hardware) == true ? ' hw' : ''}',
      if (i != null) 'fed ${i['fed']}  decoded ${i['decoded']}  errors ${i['errors']}',
      if (i?['error'] != null) '${i!['error']}',
      'fps ${st['frames'] ?? '-'}/${st['fps'] ?? '-'}  delay ${st['delay_ms'] ?? '-'} ms  enc ${st['encode_ms'] ?? '-'} ms',
      'bitrate ${st['bitrate'] is num ? '${((st['bitrate'] as num) / 1e6).toStringAsFixed(1)} Mb/s' : '-'}  ${st['video'] ?? ''}',
      'frames in ${s.framesShown}  session ${s.id}  ${s.state}',
    ];
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(6),
        color: Colors.black.withValues(alpha: 0.6),
        child: Text(
          lines.join('\n'),
          style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

/// The host's OS label for an About (empty = Linux).
String osLabel(About a) => a.hostOs.label;

/// The decoder's SurfaceView (MainActivity's `kyokai/video-view`), composed
/// into the page; Flutter keeps the touches and draws over it.
class _VideoView extends StatelessWidget {
  const _VideoView({super.key, required this.video});
  final int video;

  static const _type = 'kyokai/video-view';

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: PlatformViewLink(
      viewType: _type,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const {},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) =>
          PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: _type,
              layoutDirection: TextDirection.ltr,
              creationParams: {'video': video},
              creationParamsCodec: const StandardMessageCodec(),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
    ),
  );
}
