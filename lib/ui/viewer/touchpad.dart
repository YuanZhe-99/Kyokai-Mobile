// A touchpad: fingers in, pointer motion, clicks and scrolling out, as a
// laptop's precision touchpad behaves (after libinput's tap and
// acceleration rules). The remote screen in trackpad mode and the split
// keyboard's touchpad both use it.
//
// - Motion: with a speed-dependent gain (slow is precise, fast goes far);
//   it waits for a few pixels or a moment before it starts, so a tap does
//   not nudge the pointer, then sends what it held back.
// - Tap: one finger clicks, two right-click, three middle-click. A tap's
//   button stays down briefly: touch again then and it drags (tap-and-drag);
//   lift mid-drag and a short grace keeps the button down; a second tap is
//   a double click.
// - Two fingers: scroll, smooth (fractional notches), locked to an axis
//   when one dominates, with inertia after a flick; or pinch, where the
//   owner zooms.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

/// Where a [Touchpad]'s output goes.
abstract interface class TouchpadSink {
  /// The pointer moved by this many logical pixels (acceleration applied).
  void move(Offset delta);

  /// A button went down or up: 0 primary, 1 secondary, 2 middle.
  void button(int button, bool down);

  /// Scroll by wheel notches; positive dy moves the content down.
  void scroll(Offset notches);

  /// Two fingers pinched: the span grew by [scale] around [focal], which
  /// moved by [pan] (logical pixels).
  void pinch(double scale, Offset focal, Offset pan);
}

class Touchpad {
  Touchpad(this.sink, {this.pinch = false, this.speed = 1.0});

  final TouchpadSink sink;

  /// Whether two fingers may pinch (the screen zooms; a small pad does not).
  final bool pinch;

  /// The user's pointer speed, 1 being the default.
  double speed;

  // The rules' numbers, in logical pixels and milliseconds.
  static const slop = 6.0;
  static const tapTime = 250;
  static const tapHold = 180; // a tap's button stays down this long
  static const dragGrace = 320; // lifted mid-drag, the button waits this long
  static const pxPerNotch = 48.0;
  static const _frame = Duration(milliseconds: 16);

  final _touches = <int, _Touch>{};
  int _most = 0;
  Duration _began = Duration.zero;
  _Mode _mode = _Mode.none;

  // Motion held back until it is clearly not a tap.
  bool _released = false;
  Offset _held = Offset.zero;
  final _samples = <(Duration, double)>[];

  // Buttons: a tap's press waiting to be released, a drag holding it.
  Timer? _tapRelease;
  Timer? _dragRelease;
  bool _dragging = false;
  bool _gestureMoved = false;

  // Two fingers.
  Offset _focal = Offset.zero;
  double _span = 0;
  Offset _twoTravel = Offset.zero;
  double _spanStart = 0;
  _Axis _axis = _Axis.free;
  final _scrollSamples = <(Duration, Offset)>[];
  Timer? _inertia;

  bool get active => _touches.isNotEmpty;

  void down(int id, Offset at, Duration time) {
    _stopInertia();
    if (_touches.isEmpty) {
      _most = 0;
      _began = time;
      _mode = _Mode.none;
      _released = false;
      _held = Offset.zero;
      _samples.clear();
      _vAt = null;
      _gestureMoved = false;
      // Touching again while a tap's button is still down, or within a
      // drag's grace: the button stays down and this touch drags.
      if (_tapRelease != null || _dragRelease != null) {
        _tapRelease?.cancel();
        _dragRelease?.cancel();
        _tapRelease = null;
        _dragRelease = null;
        _dragging = true;
      }
    }
    _touches[id] = _Touch(at);
    _most = math.max(_most, _touches.length);
    if (_touches.length == 2) {
      _mode = _Mode.two;
      _focal = _centroid;
      _span = _spread;
      _spanStart = _span;
      _twoTravel = Offset.zero;
      _axis = _Axis.free;
      _scrollSamples.clear();
    }
  }

  void move(int id, Offset at, Duration time) {
    final t = _touches[id];
    if (t == null) return;
    final d = at - t.last;
    t.last = at;
    if (_touches.length >= 2) {
      _two(time);
      return;
    }
    // One finger left of two: it moves nothing until all lift.
    if (_most > 1) return;
    _one(d, time);
  }

  void up(int id, Duration time) {
    final t = _touches.remove(id);
    if (t == null) return;
    if (_touches.length == 1 && _mode == _Mode.two) {
      // The other finger stays: keep its place, no jump when it moves.
      _focal = _centroid;
    }
    if (_touches.isNotEmpty) return;
    final short = (time - _began).inMilliseconds <= tapTime;
    final tap = short && !_gestureMoved && _mode != _Mode.scroll && _mode != _Mode.pinch;
    if (_mode == _Mode.scroll) _flick(time);
    if (_dragging) {
      if (tap && _most == 1) {
        // Tap, tap: a double click.
        sink.button(0, false);
        sink.button(0, true);
        sink.button(0, false);
        _dragging = false;
      } else if (_gestureMoved && _most == 1) {
        _dragRelease = Timer(const Duration(milliseconds: dragGrace), () {
          _dragRelease = null;
          _dragging = false;
          sink.button(0, false);
        });
      } else {
        _dragging = false;
        sink.button(0, false);
      }
      return;
    }
    if (!tap) return;
    switch (_most) {
      case 1:
        sink.button(0, true);
        _tapRelease = Timer(const Duration(milliseconds: tapHold), () {
          _tapRelease = null;
          sink.button(0, false);
        });
      case 2:
        sink.button(1, true);
        sink.button(1, false);
      case 3:
        sink.button(2, true);
        sink.button(2, false);
    }
  }

  void cancel(int id) {
    _touches.remove(id);
    if (_touches.isEmpty && _dragging) {
      _dragging = false;
      sink.button(0, false);
    }
  }

  /// Lets go of everything (the pad goes away).
  void reset() {
    _stopInertia();
    _tapRelease?.cancel();
    _dragRelease?.cancel();
    if (_tapRelease != null || _dragRelease != null || _dragging) sink.button(0, false);
    _tapRelease = null;
    _dragRelease = null;
    _dragging = false;
    _touches.clear();
  }

  // ---- One finger ------------------------------------------------------------

  void _one(Offset d, Duration time) {
    _samples.add((time, d.distance));
    _samples.removeWhere((s) => time - s.$1 > const Duration(milliseconds: 60));
    if (!_released) {
      _held += d;
      final waited = (time - _began).inMilliseconds > tapTime;
      if (_held.distance < slop && !waited) return;
      _released = true;
      _gestureMoved = _gestureMoved || _held.distance >= slop;
      _mode = _Mode.pointer;
      d = _held;
    }
    if (d == Offset.zero) return;
    _gestureMoved = true;
    sink.move(d * (speed * gain(_smoothVelocity(time))));
  }

  // The speed the gain follows, smoothed over about 40 ms: raw per-event
  // speeds are noisy (touch and display rates differ), and a gain that
  // flickers with them makes a slow, steady finger shake the pointer.
  double _v = 0;
  Duration? _vAt;

  double _smoothVelocity(Duration now) {
    final v = _velocity(now);
    final last = _vAt;
    _vAt = now;
    if (last == null || now - last > const Duration(milliseconds: 100)) return _v = v;
    final dt = (now - last).inMicroseconds / 1000;
    final a = 1 - math.exp(-dt / 40);
    return _v += (v - _v) * a;
  }

  /// Logical pixels per millisecond over the last few events.
  double _velocity(Duration now) {
    if (_samples.length < 2) return 0;
    final span = (now - _samples.first.$1).inMicroseconds / 1000;
    if (span <= 0) return 0;
    return _samples.skip(1).fold(0.0, (a, s) => a + s.$2) / span;
  }

  /// The pointer's gain at a finger speed (logical px/ms): under 1 when
  /// slow, for precision; 1 at an ordinary pace; up to 3.2 for a fling.
  static double gain(double v) {
    if (v <= 0.05) return 0.7;
    if (v <= 0.35) return 0.7 + (v - 0.05) / 0.3 * 0.3;
    if (v <= 1.6) return 1.0 + (v - 0.35) / 1.25 * 2.2;
    return 3.2;
  }

  // ---- Two fingers -------------------------------------------------------------

  void _two(Duration time) {
    final focal = _centroid;
    final span = _spread;
    final d = focal - _focal;
    final scale = _span > 0 ? span / _span : 1.0;
    _focal = focal;
    _span = span;
    _twoTravel += d;
    if (_mode == _Mode.two) {
      final spanChange = (span - _spanStart).abs();
      final travel = _twoTravel.distance;
      if (math.max(spanChange, travel) < slop * 1.5) return;
      // Fingers spreading or closing more than they travel together: a pinch.
      if (pinch && _spanStart > 0 && spanChange > travel) {
        _mode = _Mode.pinch;
        sink.pinch(span / _spanStart, focal, _twoTravel);
      } else {
        _mode = _Mode.scroll;
        // One axis well ahead of the other: scroll only along it.
        final t = _twoTravel;
        _axis = t.dy.abs() > t.dx.abs() * 2
            ? _Axis.vertical
            : t.dx.abs() > t.dy.abs() * 2
            ? _Axis.horizontal
            : _Axis.free;
        _scrollBy(t, time);
      }
      return;
    }
    if (_mode == _Mode.pinch) {
      sink.pinch(scale, focal, d);
    } else if (_mode == _Mode.scroll) {
      _scrollBy(d, time);
    }
  }

  void _scrollBy(Offset fingers, Duration time) {
    final f = switch (_axis) {
      _Axis.vertical => Offset(0, fingers.dy),
      _Axis.horizontal => Offset(fingers.dx, 0),
      _Axis.free => fingers,
    };
    if (f == Offset.zero) return;
    // Natural scrolling: the content follows the fingers.
    final notches = Offset(-f.dx, f.dy) / pxPerNotch;
    _scrollSamples.add((time, notches));
    _scrollSamples.removeWhere((s) => time - s.$1 > const Duration(milliseconds: 80));
    sink.scroll(notches);
  }

  /// Fingers lifted while scrolling fast: the scroll coasts and slows.
  void _flick(Duration now) {
    if (_scrollSamples.length < 2) return;
    // The fingers stopped before they lifted: no coasting.
    if (now - _scrollSamples.last.$1 > const Duration(milliseconds: 50)) return;
    final span = (now - _scrollSamples.first.$1).inMicroseconds / 1000;
    if (span <= 0 || span > 120) return;
    var v = _scrollSamples.fold(Offset.zero, (a, s) => a + s.$2) / span; // notches/ms
    if (v.distance < 0.005) return;
    _inertia = Timer.periodic(_frame, (t) {
      v *= 0.93;
      if (v.distance < 0.002) {
        _stopInertia();
        return;
      }
      sink.scroll(v * _frame.inMilliseconds.toDouble());
    });
  }

  void _stopInertia() {
    _inertia?.cancel();
    _inertia = null;
  }

  Offset get _centroid {
    var sum = Offset.zero;
    for (final t in _touches.values) {
      sum += t.last;
    }
    return _touches.isEmpty ? Offset.zero : sum / _touches.length.toDouble();
  }

  double get _spread {
    final pts = _touches.values.map((t) => t.last).take(2).toList();
    return pts.length < 2 ? 0 : (pts[0] - pts[1]).distance;
  }
}

enum _Mode { none, pointer, two, scroll, pinch }

enum _Axis { free, vertical, horizontal }

class _Touch {
  _Touch(this.last);
  Offset last;
}
