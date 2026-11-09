// The remote screen and the fingers on it.
//
// The picture is fitted into the view and can be zoomed (pinch) and panned.
// Two pointer modes:
//
// - Trackpad: the host's pointer is a cursor of its own that a finger drags
//   along, as a laptop's touchpad. Tap clicks, two-finger tap right-clicks,
//   double-tap-and-drag drags, two fingers scroll, pinch zooms.
// - Touch: the pointer goes where the finger is. Tap clicks there, long
//   press right-clicks, a drag drags, two fingers scroll, pinch zooms.
//
// Every position the host gets is a fraction (0–1) of the shared picture,
// as Kyokai's input events take them (core input.rs `Event::Pointer`).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/prefs.dart';

/// Where the surface's pointer input goes.
abstract interface class PointerSink {
  /// The pointer moved to (x, y), fractions of the picture.
  void move(double x, double y);

  /// A button went down or up at (x, y): 0 primary, 1 secondary, 2 middle.
  void button(int button, bool down, double x, double y);

  /// Scroll by lines; positive dy moves the content down.
  void scroll(double dx, double dy);
}

/// The view's zoom and pan, and where the picture lies in it.
class RemoteViewport extends ChangeNotifier {
  /// The picture's size in pixels (the host's display).
  Size picture = const Size(1920, 1080);

  /// The view's size in logical pixels.
  Size view = Size.zero;

  double scale = 1;

  /// The picture's top-left corner in the view, after zoom.
  Offset origin = Offset.zero;

  /// The trackpad cursor, in picture fractions.
  Offset cursor = const Offset(0.5, 0.5);

  double get _fit => view.isEmpty || picture.isEmpty
      ? 1
      : math.min(view.width / picture.width, view.height / picture.height);

  /// The picture's size on screen.
  Size get shown => picture * (_fit * scale);

  void layout(Size view, Size picture) {
    if (view == this.view && picture == this.picture) return;
    this.view = view;
    this.picture = picture;
    _clamp();
  }

  void reset() {
    scale = 1;
    _clamp();
    notifyListeners();
  }

  /// Zooms by [factor] around [focal], a point in the view.
  void zoom(double factor, Offset focal) {
    final next = (scale * factor).clamp(1.0, 6.0);
    final f = next / scale;
    origin = focal - (focal - origin) * f;
    scale = next;
    _clamp();
    notifyListeners();
  }

  void pan(Offset delta) {
    origin += delta;
    _clamp();
    notifyListeners();
  }

  /// Keeps the picture filling the view where it is larger, centred where
  /// it is smaller.
  void _clamp() {
    final s = shown;
    double axis(double o, double size, double box) =>
        size <= box ? (box - size) / 2 : o.clamp(box - size, 0.0);
    origin = Offset(axis(origin.dx, s.width, view.width), axis(origin.dy, s.height, view.height));
  }

  /// A point in the view as picture fractions (clamped into the picture).
  Offset toPicture(Offset p) {
    final s = shown;
    if (s.isEmpty) return const Offset(0.5, 0.5);
    return Offset(((p.dx - origin.dx) / s.width).clamp(0.0, 1.0), ((p.dy - origin.dy) / s.height).clamp(0.0, 1.0));
  }

  /// Picture fractions as a point in the view.
  Offset toView(Offset f) => origin + Offset(f.dx * shown.width, f.dy * shown.height);

  /// Pans so a picture point stays in view (the trackpad cursor near an edge).
  void follow(Offset f) {
    if (scale <= 1) return;
    final p = toView(f);
    const margin = 40.0;
    var d = Offset.zero;
    if (p.dx < margin) d += Offset(margin - p.dx, 0);
    if (p.dx > view.width - margin) d += Offset(view.width - margin - p.dx, 0);
    if (p.dy < margin) d += Offset(0, margin - p.dy);
    if (p.dy > view.height - margin) d += Offset(0, view.height - margin - p.dy);
    if (d != Offset.zero) pan(d);
  }

  /// The part of the picture in view, as fractions (for the minimap).
  Rect get visible {
    final s = shown;
    if (s.isEmpty) return const Rect.fromLTWH(0, 0, 1, 1);
    return Rect.fromLTWH(-origin.dx / s.width, -origin.dy / s.height, view.width / s.width, view.height / s.height)
        .intersect(const Rect.fromLTWH(0, 0, 1, 1));
  }
}

class RemoteSurface extends StatefulWidget {
  const RemoteSurface({
    super.key,
    required this.viewport,
    required this.sink,
    required this.mode,
    required this.child,
    this.speed = 1.6,
    this.cursor,
  });

  final RemoteViewport viewport;
  final PointerSink sink;
  final PointerMode mode;
  final double speed;

  /// The picture (the decoder's texture).
  final Widget child;

  /// The host's cursor image, drawn at the trackpad cursor; a ring when null.
  final Widget? cursor;

  @override
  State<RemoteSurface> createState() => _RemoteSurfaceState();
}

class _Finger {
  _Finger(this.start, this.time) : last = start;
  final Offset start;
  final Duration time;
  Offset last;
  bool moved = false;
}

class _RemoteSurfaceState extends State<RemoteSurface> {
  final _fingers = <int, _Finger>{};

  /// The most fingers down at once during this gesture.
  int _most = 0;
  bool _scrolling = false;
  bool _pinching = false;
  double? _pinchSpan;
  Offset? _pinchFocal;
  Offset _scrollRest = Offset.zero;

  /// Trackpad: the last tap's end, for tap-and-drag.
  Duration? _lastTapEnd;
  Offset? _lastTapAt;
  bool _dragging = false;

  /// Touch: a long press turned into a right click; a drag holds the button.
  Timer? _longPress;
  bool _longPressed = false;
  bool _touchDown = false;

  RemoteViewport get vp => widget.viewport;
  PointerSink get sink => widget.sink;
  bool get trackpad => widget.mode == PointerMode.trackpad;

  static const _slop = 8.0;

  Offset get _centroid {
    var sum = Offset.zero;
    for (final f in _fingers.values) {
      sum += f.last;
    }
    return sum / _fingers.length.toDouble();
  }

  double get _span {
    final pts = _fingers.values.map((f) => f.last).toList();
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _fingers[e.pointer] = _Finger(e.localPosition, e.timeStamp);
    _most = math.max(_most, _fingers.length);
    if (_fingers.length == 2) {
      _longPress?.cancel();
      _pinchSpan = _span;
      _pinchFocal = _centroid;
      if (!trackpad && _touchDown) {
        // The second finger arrived before the first moved: no click.
        _touchDown = false;
      }
      return;
    }
    if (_fingers.length > 1) return;
    _scrolling = false;
    _pinching = false;
    _scrollRest = Offset.zero;
    if (trackpad) {
      final last = _lastTapEnd;
      final quick = last != null && e.timeStamp - last < const Duration(milliseconds: 280);
      final near = _lastTapAt != null && (e.localPosition - _lastTapAt!).distance < 40;
      if (quick && near) {
        // Tap, then touch again: a drag with the button held.
        _dragging = true;
        final c = vp.cursor;
        sink.button(0, true, c.dx, c.dy);
      }
    } else {
      _longPressed = false;
      _longPress = Timer(const Duration(milliseconds: 500), () {
        final f = _fingers[e.pointer];
        if (f == null || f.moved || _fingers.length != 1) return;
        _longPressed = true;
        HapticFeedback.mediumImpact();
        final p = vp.toPicture(f.last);
        sink.move(p.dx, p.dy);
        sink.button(1, true, p.dx, p.dy);
        sink.button(1, false, p.dx, p.dy);
      });
    }
  }

  void _move(PointerMoveEvent e) {
    final f = _fingers[e.pointer];
    if (f == null) return;
    final prev = f.last;
    f.last = e.localPosition;
    if (!f.moved && (f.last - f.start).distance > _slop) f.moved = true;

    if (_fingers.length >= 2) {
      final span = _span;
      final focal = _centroid;
      final s0 = _pinchSpan ?? span;
      final f0 = _pinchFocal ?? focal;
      if (!_scrolling && !_pinching && s0 > 0) {
        if ((span / s0 - 1).abs() > 0.08) {
          _pinching = true;
        } else if ((focal - f0).distance > _slop) {
          _scrolling = true;
        }
      }
      if (_pinching && s0 > 0 && span > 0) {
        vp.zoom(span / s0, focal);
        vp.pan(focal - f0);
      } else if (_scrolling) {
        // About one line per 24 logical pixels; natural scrolling.
        _scrollRest += (focal - f0) / 24;
        final lines = Offset(_scrollRest.dx.truncateToDouble(), _scrollRest.dy.truncateToDouble());
        if (lines != Offset.zero) {
          sink.scroll(-lines.dx, lines.dy);
          _scrollRest -= lines;
        }
      }
      _pinchSpan = span;
      _pinchFocal = focal;
      return;
    }
    if (_most > 1) return;

    if (trackpad) {
      if (!f.moved) return;
      final d = f.last - prev;
      final shown = vp.shown;
      if (shown.isEmpty) return;
      // Faster swipes go further, as a touchpad's acceleration.
      final v = d.distance;
      final gain = widget.speed * (1 + math.min(v / 30, 1.5));
      final next = vp.cursor + Offset(d.dx * gain / shown.width * vp.scale, d.dy * gain / shown.height * vp.scale);
      vp.cursor = Offset(next.dx.clamp(0.0, 1.0), next.dy.clamp(0.0, 1.0));
      sink.move(vp.cursor.dx, vp.cursor.dy);
      vp.follow(vp.cursor);
      setState(() {});
    } else {
      if (!f.moved || _longPressed) return;
      _longPress?.cancel();
      final p = vp.toPicture(f.last);
      if (!_touchDown) {
        final s = vp.toPicture(f.start);
        sink.move(s.dx, s.dy);
        sink.button(0, true, s.dx, s.dy);
        _touchDown = true;
      }
      sink.move(p.dx, p.dy);
    }
  }

  void _up(PointerEvent e) {
    final f = _fingers.remove(e.pointer);
    if (f == null) return;
    if (_fingers.isNotEmpty) return;
    _longPress?.cancel();
    final tap = !f.moved && e.timeStamp - f.time < const Duration(milliseconds: 300) && !_scrolling && !_pinching;
    final most = _most;
    _most = 0;
    _pinchSpan = null;
    _pinchFocal = null;

    if (trackpad) {
      final c = vp.cursor;
      if (_dragging) {
        _dragging = false;
        sink.button(0, false, c.dx, c.dy);
        _lastTapEnd = null;
        return;
      }
      if (tap && most == 1) {
        sink.button(0, true, c.dx, c.dy);
        sink.button(0, false, c.dx, c.dy);
        _lastTapEnd = e.timeStamp;
        _lastTapAt = f.last;
      } else if (tap && most == 2) {
        sink.button(1, true, c.dx, c.dy);
        sink.button(1, false, c.dx, c.dy);
      } else if (tap && most == 3) {
        sink.button(2, true, c.dx, c.dy);
        sink.button(2, false, c.dx, c.dy);
      }
    } else {
      final p = vp.toPicture(f.last);
      if (_touchDown) {
        _touchDown = false;
        sink.move(p.dx, p.dy);
        sink.button(0, false, p.dx, p.dy);
      } else if (tap && most == 1 && !_longPressed) {
        sink.move(p.dx, p.dy);
        sink.button(0, true, p.dx, p.dy);
        sink.button(0, false, p.dx, p.dy);
        vp.cursor = p;
      } else if (tap && most == 2) {
        final c = vp.toPicture(f.last);
        sink.button(1, true, c.dx, c.dy);
        sink.button(1, false, c.dx, c.dy);
      }
    }
  }

  /// A mouse or stylus: the pointer follows it, its buttons are the host's.
  void _hover(PointerHoverEvent e) {
    final p = vp.toPicture(e.localPosition);
    vp.cursor = p;
    sink.move(p.dx, p.dy);
  }

  int _mouseButtons = 0;

  void _mouse(PointerEvent e) {
    final p = vp.toPicture(e.localPosition);
    vp.cursor = p;
    sink.move(p.dx, p.dy);
    final changed = e.buttons ^ _mouseButtons;
    for (final (bit, button) in [(kPrimaryMouseButton, 0), (kSecondaryMouseButton, 1), (kMiddleMouseButton, 2)]) {
      if (changed & bit != 0) sink.button(button, e.buttons & bit != 0, p.dx, p.dy);
    }
    _mouseButtons = e.buttons;
  }

  @override
  void dispose() {
    _longPress?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      vp.layout(box.biggest, vp.picture);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => e.kind == PointerDeviceKind.mouse ? _mouse(e) : _down(e),
        onPointerMove: (e) => e.kind == PointerDeviceKind.mouse ? _mouse(e) : _move(e),
        onPointerUp: (e) => e.kind == PointerDeviceKind.mouse ? _mouse(e) : _up(e),
        onPointerCancel: _up,
        onPointerHover: _hover,
        onPointerSignal: (s) {
          if (s is PointerScrollEvent) sink.scroll(s.scrollDelta.dx / 40, -s.scrollDelta.dy / 40);
        },
        child: ClipRect(
          child: ListenableBuilder(
            listenable: vp,
            builder: (context, _) {
              final shown = vp.shown;
              final c = vp.toView(vp.cursor);
              return Stack(
                children: [
                  Positioned(
                    left: vp.origin.dx,
                    top: vp.origin.dy,
                    width: shown.width,
                    height: shown.height,
                    child: widget.child,
                  ),
                  if (trackpad)
                    Positioned(
                      left: c.dx - 11,
                      top: c.dy - 11,
                      child: IgnorePointer(
                        child: widget.cursor ??
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                                boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9), spreadRadius: 2)],
                              ),
                            ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

/// Where the zoomed view is on the screen.
class Minimap extends StatelessWidget {
  const Minimap({super.key, required this.viewport});
  final RemoteViewport viewport;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewport,
    builder: (context, _) {
      if (viewport.scale <= 1.01) return const SizedBox.shrink();
      final cs = Theme.of(context).colorScheme;
      final aspect = viewport.picture.isEmpty ? 16 / 9 : viewport.picture.width / viewport.picture.height;
      const w = 96.0;
      final h = w / aspect;
      final v = viewport.visible;
      return Container(
        width: w + 6,
        height: h + 6,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: cs.surfaceContainerHighest)),
            Positioned(
              left: v.left * w,
              top: v.top * h,
              width: v.width * w,
              height: v.height * h,
              child: Container(decoration: BoxDecoration(border: Border.all(color: cs.primary, width: 1.5))),
            ),
          ],
        ),
      );
    },
  );
}
