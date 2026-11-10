
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/ui/viewer/touchpad.dart';

class _Out implements TouchpadSink {
  final events = <String>[];
  Offset moved = Offset.zero;
  Offset scrolled = Offset.zero;
  double zoom = 1;

  @override
  void move(Offset d) => moved += d;
  @override
  void button(int b, bool down) => events.add('${down ? 'down' : 'up'}$b');
  @override
  void scroll(Offset n) => scrolled += n;
  @override
  void pinch(double scale, Offset focal, Offset pan) => zoom *= scale;
}

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  test('a tap clicks once its button has been down a moment', () {
    fakeAsync((a) {
      final out = _Out();
      final p = Touchpad(out);
      p.down(1, const Offset(50, 50), ms(0));
      p.move(1, const Offset(52, 51), ms(40));
      p.up(1, ms(90));
      expect(out.events, ['down0']);
      a.elapse(ms(Touchpad.tapHold + 10));
      expect(out.events, ['down0', 'up0']);
      expect(out.moved, Offset.zero, reason: 'a tap does not nudge the pointer');
    });
  });

  test('tap then touch again drags, and the grace keeps the button', () {
    fakeAsync((a) {
      final out = _Out();
      final p = Touchpad(out);
      p.down(1, const Offset(50, 50), ms(0));
      p.up(1, ms(80));
      a.elapse(ms(100));
      p.down(2, const Offset(50, 50), ms(180));
      for (var i = 1; i <= 10; i++) {
        p.move(2, Offset(50 + i * 5.0, 50), ms(180 + i * 16));
      }
      p.up(2, ms(400));
      a.elapse(ms(100));
      expect(out.events, ['down0'], reason: 'still dragging within the grace');
      expect(out.moved.dx, greaterThan(0));
      a.elapse(ms(Touchpad.dragGrace));
      expect(out.events, ['down0', 'up0']);
    });
  });

  test('two taps are a double click', () {
    fakeAsync((a) {
      final out = _Out();
      final p = Touchpad(out);
      p.down(1, const Offset(50, 50), ms(0));
      p.up(1, ms(70));
      a.elapse(ms(90));
      p.down(2, const Offset(51, 50), ms(160));
      p.up(2, ms(230));
      a.elapse(ms(500));
      expect(out.events, ['down0', 'up0', 'down0', 'up0']);
    });
  });

  test('two fingers tap a right click, three a middle click', () {
    fakeAsync((a) {
      final out = _Out();
      final p = Touchpad(out);
      p.down(1, const Offset(40, 50), ms(0));
      p.down(2, const Offset(80, 50), ms(10));
      p.up(1, ms(90));
      p.up(2, ms(100));
      p.down(3, const Offset(40, 50), ms(1000));
      p.down(4, const Offset(60, 50), ms(1005));
      p.down(5, const Offset(80, 50), ms(1010));
      p.up(3, ms(1080));
      p.up(4, ms(1085));
      p.up(5, ms(1090));
      a.elapse(ms(500));
      expect(out.events, ['down1', 'up1', 'down2', 'up2']);
    });
  });

  test('two fingers scroll smoothly, locked to the axis that leads', () {
    fakeAsync((a) {
      final out = _Out();
      final p = Touchpad(out);
      p.down(1, const Offset(40, 100), ms(0));
      p.down(2, const Offset(80, 100), ms(5));
      for (var i = 1; i <= 12; i++) {
        p.move(1, Offset(40 + i * 0.5, 100.0 + i * 8), ms(i * 16));
        p.move(2, Offset(80 + i * 0.5, 100.0 + i * 8), ms(i * 16));
      }
      expect(out.scrolled.dx, 0, reason: 'locked vertical');
      expect(out.scrolled.dy, greaterThan(1));
      expect(out.scrolled.dy, lessThan(96 / Touchpad.pxPerNotch + 0.01));
      p.up(1, ms(200));
      p.up(2, ms(200));
      final lifted = out.scrolled.dy;
      a.elapse(ms(300));
      expect(out.scrolled.dy, greaterThan(lifted), reason: 'it coasts after a flick');
      expect(out.events, isEmpty);
    });
  });

  test('the screen pinches; a small pad never does', () {
    for (final pinch in [true, false]) {
      final out = _Out();
      final p = Touchpad(out, pinch: pinch);
      p.down(1, const Offset(100, 100), ms(0));
      p.down(2, const Offset(140, 100), ms(5));
      for (var i = 1; i <= 10; i++) {
        p.move(2, Offset(140.0 + i * 8, 100), ms(i * 16));
      }
      expect(out.zoom > 1.5, pinch);
    }
  });

  test('the gain is precise when slow and far-reaching when fast', () {
    expect(Touchpad.gain(0.01), lessThan(1));
    expect(Touchpad.gain(0.4), closeTo(1.09, 0.05));
    expect(Touchpad.gain(5), 3.2);
    var last = 0.0;
    for (var v = 0.0; v < 3; v += 0.05) {
      expect(Touchpad.gain(v), greaterThanOrEqualTo(last));
      last = Touchpad.gain(v);
    }
  });

  test('a second finger moves no pointer, and the first resumes without a jump', () {
    final out = _Out();
    final p = Touchpad(out);
    p.down(1, const Offset(50, 50), ms(0));
    p.move(1, const Offset(80, 50), ms(30));
    final before = out.moved;
    p.down(2, const Offset(200, 50), ms(40));
    p.move(2, const Offset(260, 50), ms(60));
    p.up(2, ms(80));
    p.move(1, const Offset(81, 50), ms(100));
    expect(out.moved, before);
  });
}
