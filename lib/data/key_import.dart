// Reads a sign-in key file into what the core's `keys.add` keeps: an
// Ed25519 seed, else PKCS#8 DER, base64 (as internal/gui/keys.go importKey
// does on the desktop).
//
// Read here: OpenSSH keys (Ed25519, RSA) without a passphrase, PEM PKCS#8
// ("PRIVATE KEY") and PEM PKCS#1 ("RSA PRIVATE KEY"). Not yet: keys with a
// passphrase and OpenSSH or SEC1 ECDSA keys (KeyImportError.unsupported).

import 'dart:convert';
import 'dart:typed_data';

enum KeyImportError {
  /// Not a private key this reads.
  notAKey,

  /// It has a passphrase.
  locked,

  /// A kind of key this build cannot read yet.
  unsupported,
}

class KeyImportException implements Exception {
  KeyImportException(this.error);
  final KeyImportError error;
  @override
  String toString() => 'KeyImportException(${error.name})';
}

/// The private part for `keys.add`, base64, from a key file's text.
String importPrivateKey(String text) {
  final pem = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----').firstMatch(text);
  if (pem == null) throw KeyImportException(KeyImportError.notAKey);
  final label = pem.group(1)!;
  final body = pem.group(2)!;
  if (body.contains('Proc-Type: 4,ENCRYPTED')) throw KeyImportException(KeyImportError.locked);
  final Uint8List der;
  try {
    der = base64.decode(body.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw KeyImportException(KeyImportError.notAKey);
  }
  switch (label) {
    case 'OPENSSH PRIVATE KEY':
      return base64.encode(_openSsh(der));
    case 'PRIVATE KEY':
      return base64.encode(_ed25519Seed(der) ?? der);
    case 'RSA PRIVATE KEY':
      return base64.encode(_rsaPkcs8(der));
    case 'ENCRYPTED PRIVATE KEY':
      throw KeyImportException(KeyImportError.locked);
    case 'EC PRIVATE KEY':
      throw KeyImportException(KeyImportError.unsupported);
    default:
      throw KeyImportException(KeyImportError.notAKey);
  }
}

/// An Ed25519 PKCS#8 key's seed (OID 1.3.101.112), or null for another kind.
Uint8List? _ed25519Seed(Uint8List der) {
  const oid = [0x06, 0x03, 0x2B, 0x65, 0x70];
  for (var i = 0; i + oid.length <= der.length; i++) {
    var match = true;
    for (var j = 0; j < oid.length; j++) {
      if (der[i + j] != oid[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      // ... OCTET STRING { OCTET STRING (32) seed }: the seed ends the key
      // when no attributes or public key follow, as OpenSSL writes it.
      final at = _find(der, const [0x04, 0x22, 0x04, 0x20], i);
      if (at < 0 || at + 4 + 32 > der.length) throw KeyImportException(KeyImportError.notAKey);
      return Uint8List.sublistView(der, at + 4, at + 36);
    }
  }
  return null;
}

int _find(Uint8List d, List<int> what, int from) {
  for (var i = from; i + what.length <= d.length; i++) {
    var ok = true;
    for (var j = 0; j < what.length; j++) {
      if (d[i + j] != what[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// openssh-key-v1 (PROTOCOL.key): the Ed25519 seed, or an RSA key as PKCS#8.
Uint8List _openSsh(Uint8List d) {
  final r = _SshReader(d);
  const magic = 'openssh-key-v1\x00';
  if (d.length < magic.length || ascii.decode(d.sublist(0, magic.length), allowInvalid: true) != magic) {
    throw KeyImportException(KeyImportError.notAKey);
  }
  r.at = magic.length;
  final cipher = r.text();
  r.text(); // kdf name
  r.bytes(); // kdf options
  if (cipher != 'none') throw KeyImportException(KeyImportError.locked);
  if (r.u32() != 1) throw KeyImportException(KeyImportError.notAKey);
  r.bytes(); // the public key
  final p = _SshReader(r.bytes());
  if (p.u32() != p.u32()) throw KeyImportException(KeyImportError.notAKey);
  final type = p.text();
  switch (type) {
    case 'ssh-ed25519':
      p.bytes(); // public
      final private = p.bytes(); // seed + public
      if (private.length != 64) throw KeyImportException(KeyImportError.notAKey);
      return Uint8List.fromList(private.sublist(0, 32));
    case 'ssh-rsa':
      final n = p.mpint(), e = p.mpint(), dd = p.mpint(), iqmp = p.mpint(), pp = p.mpint(), q = p.mpint();
      if (n.bitLength < 2048) throw KeyImportException(KeyImportError.unsupported);
      final pkcs1 = _seq([
        _int(BigInt.zero),
        _int(n),
        _int(e),
        _int(dd),
        _int(pp),
        _int(q),
        _int(dd % (pp - BigInt.one)),
        _int(dd % (q - BigInt.one)),
        _int(iqmp),
      ]);
      return _rsaPkcs8(pkcs1);
    default:
      throw KeyImportException(KeyImportError.unsupported);
  }
}

/// PKCS#1 RSAPrivateKey wrapped as PKCS#8 (rsaEncryption, NULL).
Uint8List _rsaPkcs8(Uint8List pkcs1) => _seq([
  _int(BigInt.zero),
  _seq([
    Uint8List.fromList(const [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]),
    Uint8List.fromList(const [0x05, 0x00]),
  ]),
  _tlv(0x04, pkcs1),
]);

Uint8List _seq(List<Uint8List> parts) => _tlv(0x30, Uint8List.fromList([for (final p in parts) ...p]));

Uint8List _int(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _tlv(0x02, Uint8List.fromList(bytes));
}

Uint8List _tlv(int tag, Uint8List body) {
  final n = body.length;
  final len = n < 0x80
      ? [n]
      : n < 0x100
      ? [0x81, n]
      : n < 0x10000
      ? [0x82, n >> 8, n & 0xFF]
      : [0x83, n >> 16, (n >> 8) & 0xFF, n & 0xFF];
  return Uint8List.fromList([tag, ...len, ...body]);
}

class _SshReader {
  _SshReader(this.d);
  final Uint8List d;
  int at = 0;

  int u32() {
    if (at + 4 > d.length) throw KeyImportException(KeyImportError.notAKey);
    final v = ByteData.sublistView(d, at, at + 4).getUint32(0);
    at += 4;
    return v;
  }

  Uint8List bytes() {
    final n = u32();
    if (at + n > d.length) throw KeyImportException(KeyImportError.notAKey);
    final v = Uint8List.sublistView(d, at, at + n);
    at += n;
    return v;
  }

  String text() => utf8.decode(bytes(), allowMalformed: true);

  BigInt mpint() {
    final b = bytes();
    var v = BigInt.zero;
    for (final x in b) {
      v = (v << 8) | BigInt.from(x);
    }
    return v;
  }
}
