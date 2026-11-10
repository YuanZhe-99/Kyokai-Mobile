import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/core/clients.dart';
import 'package:kyokai_mobile/data/services.dart';

Uint8List _p(int kind, List<int> body) => Uint8List.fromList([kind, ...body]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('states, a shell\'s output split mid-character, and the host\'s clipboard', () {
    final s = ServiceSession('123456789', ServiceKind.ssh, 'Box');
    s.packetForTest(_p(ClientPacket.state, utf8.encode('{"state":"failed","error":"host-key-changed","host_key":"ssh-ed25519 AAAA"}')));
    expect(s.state, 'failed');
    expect(s.error, 'host-key-changed');
    expect(s.hostKey, 'ssh-ed25519 AAAA');
    final bytes = utf8.encode('你好 shell');
    s.packetForTest(_p(ClientPacket.data, bytes.sublist(0, 2)));
    s.packetForTest(_p(ClientPacket.data, bytes.sublist(2)));
    expect(s.terminal.buffer.lines[0].toString(), startsWith('你好 shell'));
  });

  test('frames patch the picture where they say', () {
    final s = ServiceSession('123456789', ServiceKind.rdp, 'Desk');
    Uint8List frame(int x, int y, int w, int h, int pw, int ph, int value) {
      final head = ByteData(24);
      for (final (i, v) in [x, y, w, h, pw, ph].indexed) {
        head.setUint32(i * 4, v);
      }
      return _p(ClientPacket.frame, [...head.buffer.asUint8List(), ...List.filled(w * h * 4, value)]);
    }

    s.packetForTest(frame(0, 0, 4, 2, 4, 2, 1));
    expect((s.width, s.height), (4, 2));
    s.packetForTest(frame(2, 1, 2, 1, 4, 2, 9));
    final px = s.pixels!;
    expect(px[(1 * 4 + 2) * 4], 9, reason: '(2, 1) patched');
    expect(px[(1 * 4 + 1) * 4], 1, reason: '(1, 1) kept');
    s.packetForTest(frame(0, 0, 8, 8, 8, 8, 3));
    expect((s.width, s.height), (8, 8), reason: 'a new size starts a new picture');
  });
}
