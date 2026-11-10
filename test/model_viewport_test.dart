import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/data/model.dart';
import 'package:kyokai_mobile/ui/keyboard/keys.dart';
import 'package:kyokai_mobile/ui/viewer/surface.dart';

void main() {
  roomTests();
  pinTopTests();
  group('device IDs', () {
    test('format in groups of three', () {
      expect(formatId('123456789'), '123 456 789');
      expect(formatId('12345'), '12345');
    });
    test('parse with spaces or dashes, reject the rest', () {
      expect(parseId('123 456 789'), '123456789');
      expect(parseId('123-456-789'), '123456789');
      expect(parseId('12345678'), isNull);
      expect(parseId('host.local'), isNull);
    });
  });

  group('status', () {
    test('an empty status reads as defaults', () {
      final s = Status(const {});
      expect(s.deviceId, '');
      expect(s.sessions, isEmpty);
      expect(s.network.devices, isEmpty);
      expect(s.host('123456789'), isNull);
    });
    test('hosts and their OS', () {
      final s = Status(const {
        'recent': [
          {
            'device_id': '111222333',
            'about': {'name': 'Desk', 'os': 'macos'},
            'saved_password': true,
          },
          {'device_id': '444555666', 'about': {}},
        ],
      });
      final desk = s.host('111222333')!;
      expect(desk.title, 'Desk');
      expect(desk.about.hostOs, HostOs.macos);
      expect(desk.savedPassword, isTrue);
      expect(s.host('444555666')!.title, '444 555 666');
    });
  });

  group('viewport', () {
    RemoteViewport vp() => RemoteViewport()..layout(const Size(400, 400), const Size(1600, 800));

    test('fits the picture and centres it', () {
      final v = vp();
      expect(v.shown, const Size(400, 200));
      expect(v.origin, const Offset(0, 100));
    });

    test('view and picture coordinates round-trip', () {
      final v = vp();
      expect(v.toPicture(const Offset(200, 200)), const Offset(0.5, 0.5));
      expect(v.toView(const Offset(0.25, 0.75)), const Offset(100, 250));
      // Outside the picture clamps to its edge.
      expect(v.toPicture(const Offset(200, 10)).dy, 0);
    });

    test('zoom keeps the focal point and stays in bounds', () {
      final v = vp();
      final before = v.toPicture(const Offset(100, 200));
      v.zoom(2, const Offset(100, 200));
      expect(v.scale, 2);
      final after = v.toPicture(const Offset(100, 200));
      expect((after - before).distance, lessThan(1e-9));
      v.zoom(100, Offset.zero);
      expect(v.scale, 6);
      v.pan(const Offset(10000, 10000));
      expect(v.origin.dx, 0);
    });

    test('the visible part shrinks as it zooms', () {
      final v = vp();
      expect(v.visible, const Rect.fromLTWH(0, 0, 1, 1));
      v.zoom(2, const Offset(200, 200));
      expect(v.visible.width, closeTo(0.5, 1e-9));
    });
  });
}

void pinTopTests() {
  test('a short picture sits at the top when pinned, centred otherwise', () {
    final v = RemoteViewport()..layout(const Size(400, 400), const Size(1600, 800));
    expect(v.origin.dy, 100);
    v.pinTop = true;
    expect(v.origin.dy, 0);
    v.zoom(3, const Offset(200, 200));
    v.zoom(1 / 3, const Offset(200, 200));
    expect(v.origin.dy, 0, reason: 'back at the smallest, still at the top');
  });
}

void roomTests() {
  test('room below the picture for a keyboard', () {
    final v = RemoteViewport()..layout(const Size(412, 700), const Size(1600, 1000));
    // The picture is 257.5 tall at full width: 442 under it.
    expect(v.roomBelow(264), isTrue);
    expect(v.roomBelow(450), isFalse);
    expect(RemoteViewport().roomBelow(10), isFalse, reason: 'nothing laid out yet');
  });
}
