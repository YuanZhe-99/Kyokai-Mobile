# Remote services for the Android client (SSH, SFTP, RDP, VNC)

Paths are relative to `third_party/kyokai/`; line numbers as of the android branch. The design is
`doc/en-us/remote-services.md`. This overrides `api-control.md` §7 where they differ.

## 1. Tunnels

A tunnel is a controller session of kind `Tunnel(service)` carrying one byte stream to the host's
loopback service (`core/kyokai-core/src/session.rs:870`). Only `tunnel.open` makes one.

| service | permission | host port (host may override) |
|---|---|---|
| `ssh` | `use-ssh` | 22 |
| `rdp` | `use-rdp` | 3389 |
| `vnc` | `use-vnc` | 5900 |

- Pieces of at most 65 518 bytes on the wire (`tunnel.rs:23`); 60 s without frames ends it
  (`tunnel.rs:26`); the host tries its service 3 s, else `service-down`; at most 8 per host (9th: `busy`).
- Between peers announcing `move`, a dropped link resumes within 60 s; reads and writes just stall.

### Calls

| method | params | result |
|---|---|---|
| `tunnel.open` | `{device_id, service, address?, route?}` | `{id}` at once (`lib.rs:1230-1263`) |
| `tunnel.wait` | `{id, timeout_ms?}` (≤ 90 000) | `{state, failure}` (`lib.rs:1336-1352`) |
| `session.close` | `{id}` | `{}` |

`tunnel.open` signs in with the saved Kyokai password, else the sign-in keys, else asks the host's
user; `want` is `[use-<service>]`. No password parameter.

`failure`: null, a string (`unreachable`, `wrong-device`, `key-changed`, `incompatible`, `broken`,
`unsupported` = host has no `tunnel` feature) or `{"refused": password|denied|timeout|busy|rate-limited|absent|service-down}`.

Open sequence (desktop engine, `internal/engine/services.go:130-164`): `tunnel.open`; loop
`tunnel.wait {id, timeout_ms: 1000}` while `connecting`/`confirming`, up to 90 s or a cancel; not
`connected` → reason = failure string, else `failure.refused`, else `closed`/`timeout`, then
`session.close`. Pump bytes; finally `session.close`.

### Packet 14 (TUNNEL)

- Read `kyokai_media_read(id, buf, cap, ms)` → `[0x0E] ++ piece`; -1 timeout, -2 ended (EOF),
  -3 cap too small — **the piece is lost and the stream corrupt: cap ≥ 65 519** (engine: 1 + 128 KiB).
  One reader per tunnel. Before connect, reads time out; on failure, -2.
- Write `kyokai_media_write(id, [0x0E] ++ bytes)`, any length; blocks for room (the backpressure),
  never -3 for tunnels; 0 or -2 (ended). Never from inside a tokio runtime.
- Pipes hold 16 pieces each way (≈1 MiB). No half-close: it ends on `session.close`, the service
  closing, 60 s idle or failure.

As a Go `net.Conn` (desktop `internal/localapi/tunnel.go:81-126`): a `net.Pipe` with two pumps — core
→ pipe (`media_read` 500 ms, strip byte 14, -2 closes) and pipe → core (≤ 64 KiB, prefix 14). Needs
working deadlines (SSH sets 30 s; rdp's TLS sets them) and a non-nil `RemoteAddr`.

## 2. Saved service sign-ins

| method | params | result |
|---|---|---|
| `credentials.get` | `{device_id, service}` | Credentials or `{}` |
| `credentials.set` | `{device_id, service, credentials}` | `{}` |
| `credentials.forget` | `{device_id, service?}` | `{}` |

Credentials: `{"method":"key|password|account|none","user","domain","password","key_id","host_key"}`
(empty fields omitted). `set` replaces; an absent `password` keeps the old one, an empty one removes it;
an empty `host_key` keeps it. `status.recent[].saved` lists which exist (`password`, `key`, `ssh`, `rdp`, `vnc`).

Methods per service (`internal/gui/servicetab.go:79-151`): SSH `key|password`; VNC
`password|account|none`; RDP `account|none`. Remembered: `{user, domain, method, password}`
(password `""` for key/none); not remembered: `{user, domain, password:""}`. SSH also keeps `host_key`.

## 3. SSH with Kyokai keys (`internal/gui/ssh.go`)

- `keys.list` → `[{id, name, type, public, added}]`.
- `keys.sign {key_id, algorithm, data: base64}` → `{signature: base64(string alg || string sig)}`.
  `data` must be exactly the RFC 4252 §7 user-auth blob (`keys.rs:399-414`); algorithms
  `ssh-ed25519`, `rsa-sha2-256|512`, `ecdsa-sha2-nistp256|384`.
- Signers from `keys.list` via `ssh.ParseAuthorizedKey`; RSA wrapped with
  `NewSignerWithAlgorithms(rsa-sha2-512, rsa-sha2-256)`.
- Dial (`ssh.go:136-205`): user required; 30 s deadline; one method — key → `PublicKeysCallback`, else
  `PasswordCallback` + `KeyboardInteractive` with the same password, refusing a second round;
  `ssh.NewClientConn(tunnel, "localhost:22", cfg)`; errors: deadline → no answer, after kex → sign-in
  failed, host key mismatch → changed (with the offered key).
- Host keys (`ssh.go:207-243`): the first kex must match the pinned `host_key` unless the user
  trusted the new one; re-keys must match the first. Compare `TrimSpace(MarshalAuthorizedKey(k))`.
- Shell (`ssh.go:245-271`): `Setenv LANG=<locale>.UTF-8`, `COLORTERM=truecolor`;
  `RequestPty("xterm-256color", rows, cols, {ECHO:1, speeds 115200})`; stdin/stdout pipes;
  `WindowChange(rows, cols)`; close session, client, tunnel. Block OSC 52 clipboard writes.

## 4. Go clients

### `internal/rdp` (GPL-3.0-or-later)
- `rdp.Dial(ctx, Options, Events)` then `go c.Run()`; `Close()`.
- Options: `{Conn, Width, Height, Clipboard: true, DialTimeout: 30s, VerifyCertificate: func(string) error {return nil}, Username, Domain, Password}` (password only for `account`; `DOMAIN\user` is split).
- Errors: `ErrNLAUnavailable`, `ErrUnsupportedSecurity`, `ErrAuthenticationFailed`,
  `ErrRemoteLogonDenied`, `ErrSessionReplaced`, `ErrSessionEnded`, `ErrNotRDP`, `ErrRFBServer`, `ErrCertificateChanged`.
- Events: `ResizeFramebuffer(w, h) (*bgra.Image, error)`; `FramebufferUpdated(Update{Rectangle})`
  (union dirty rect; copy out in the callback); `ClipboardReceived(text)`; cursor events ignorable.
  `bgra.Image{Pix, Stride, Width, Height}` is B,G,R,A. Max 8192 a side / 32 Mpx.
- Input: `SendPointer(x, y, buttons)` (px; 1 left, 2 middle, 4 right), `SendScroll(x, y, dx, dy)`
  (px; desktop: 20 px per notch), `SendScancode(code uint8, extended, down)` (set 1),
  `SendKey(keysym, down)`, `SendText`, `SetClipboard(text)`, `SetDisplay(w, h, scale)` when `Info().Resize`.
- No H.264 on Android (VideoToolbox only); RemoteFX/ClearCodec/planar carry the picture.

### `internal/rfb` (VNC, GPL)
- `rfb.Dial(ctx, Options, Handler)` then `go c.Run()`; `Close()`.
- Options: `{Conn, Mode: ModeControl, Clipboard: true, AutomaticUpdates: true, Username, Password, SecurityTypes}`;
  `none` → `[1]`, `password` → `[2]`, `account` → `[33, 36]` (Apple). A Mac in use by someone else:
  `ChooseSession` → `SessionShareConsole`.
- Handler: 16 methods; `ResizeFramebuffer`, `FramebufferUpdated(Update{Dirty})`, `ClipboardReceived`
  matter, the rest no-ops.
- Input: `SendPointer(x, y, buttons, 0)`, `SendScroll(x, y, dx, dy)` (positive dy = wheel up),
  `SendKey(keysym, down)`, `SendText`, `SetClipboard(rfb.NewTextClipboard(text))`.

### SSH / SFTP / SCP
In `package gui` (imports MyGo), so the logic is copied into `internal/sshclient`: dial, signers,
host keys, shell; later the non-UI half of `sshfiles.go` (SFTP on the same `*ssh.Client`, SCP fallback).
Depends only on `golang.org/x/crypto/ssh` and `github.com/pkg/sftp`.

## 5. Building for Android

`internal/rdp`, `internal/rfb`, `bgra`, `outbox`, `exceptions` build for android/arm64 without cgo.
Don't import `gui`, `engine`, `helper` or `locales` (MyGo). `internal/core.Load` needs a file path the
APK doesn't have (native libraries stay packed), so the clients library takes the core's function
pointers from Dart instead. Never call `kyokai_start`/`kyokai_stop` from Go. Build with
`-buildmode=c-shared`, `CC` = the NDK's `aarch64-linux-android26-clang`.
