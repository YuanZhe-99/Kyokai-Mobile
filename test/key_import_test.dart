// The key files are throwaway keys made with ssh-keygen for this test only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/data/key_import.dart';

String _key(String name) => File('test/keys/$name.txt').readAsStringSync();

void main() {
  test('an OpenSSH Ed25519 key and its PKCS#8 form give the same seed', () {
    final seed = importPrivateKey(_key('ed25519'));
    expect(seed.length, 44); // 32 bytes, base64
    expect(importPrivateKey(_key('ed25519.pkcs8')), seed);
  });

  test('OpenSSH, PKCS#1 and PKCS#8 RSA keys give the same PKCS#8', () {
    final pkcs8 = importPrivateKey(_key('rsa.pkcs8'));
    expect(importPrivateKey(_key('rsa')), pkcs8);
    expect(importPrivateKey(_key('rsa.pem')), pkcs8);
  });

  test('a key with a passphrase, and text that is no key', () {
    expect(() => importPrivateKey(_key('locked')),
        throwsA(isA<KeyImportException>().having((e) => e.error, 'error', KeyImportError.locked)));
    expect(() => importPrivateKey('ssh-ed25519 AAAA test'),
        throwsA(isA<KeyImportException>().having((e) => e.error, 'error', KeyImportError.notAKey)));
  });
}
