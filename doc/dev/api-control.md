# Kyokai core JSON API — controller-only reference (for Kyokai-Mobile / Dart FFI)

Source tree: `third_party/kyokai` on branch `android` with its uncommitted working-tree changes
(Android module, store, lib.rs). Paths below are relative to `third_party/kyokai/`.
`lib.rs` = `core/kyokai-core/src/lib.rs`. Line numbers are of the working tree as read (2026-11-09).

Kyokai version the core expects to be told: `0.7.3` (`internal/version/version.go:13`). ABI = **8**
(`lib.rs:74`, `internal/core/core.go:20`). Wire protocol 10 (`session.rs:25`).

---

## 0. The C ABI in one page

| Export | Notes |
|---|---|
| `kyokai_abi_version() -> u32` | must be 8; the Go binding refuses any other (`internal/core/core.go:187`) |
| `kyokai_start(cfg, len, *out, *out_len) -> i32` | 0 + JSON response; -1 only for null args. Response = `{"ok":true,"result":<status>}` (the full `status`, `lib.rs:243-245`) or `{"ok":false,"error":"…"}` |
| `kyokai_call(req, len, *out, *out_len) -> i32` | `req` = `{"method":"…","params":…}` (`params` optional, default `null`, `lib.rs:209-215`). Response `{"ok":true,"result":…}` / `{"ok":false,"error":"…"}`; a panic is `{"ok":false,"error":"internal error"}` (`lib.rs:786-814`). Unknown method: `error = "unknown method \"x\""` (`lib.rs:1839`). Calls may run concurrently. |
| `kyokai_free(ptr, len)` | free every `out` buffer exactly once (`lib.rs:713`) |
| `kyokai_stop()` | closes all sessions (goodbye, ≤1 s), drops the core (`lib.rs:270-296`). Safe twice. |
| `kyokai_media_read(session, buf, cap, timeout_ms) -> i64` | next media packet of a controller session (or packet 14 for a tunnel). `-1` timeout, `-2` ended / no such session, `-3` packet > cap (packet dropped) (`lib.rs:308-337`) |
| `kyokai_media_write(session, ptr, len) -> i32` | packet `[3]+JSON` (control) or `[14]+bytes` (tunnel). `0` ok, `-1` malformed, `-2` ended, `-3` refused as behind (`lib.rs:355-397`) |
| `kyokai_decoder_*`, `kyokai_audio_*` | decoders; on Android rustdesk-codec is excluded (Cargo.toml diff), the app decodes with MediaCodec and names its codecs via `android.decoders` |
| `kyokai_keyboard_*`, `kyokai_privacy_request` | desktop/macOS only; `kyokai_keyboard_read/state` return -2 on Android (`lib.rs:655,689`) |

Errors are always human-readable English strings, never codes, except where noted (session
failures in `status`, `session.identify` failures, `tunnel.wait` failures).

Blocking calls (call them off the UI isolate): `session.identify` (dials, seconds), `tunnel.wait`
(≤ `timeout_ms`), `keys.sign` (RSA), `identity.export/import`, `store.export/import`,
`password.set_permanent`, `protect.set`, `store.start_over`, `kyokai_media_read`.
`kyokai_media_write` of a control message waits ≤200 ms (`lib.rs:401`), of tunnel bytes until room.

---

## 1. `kyokai_start` — StartConfig

`lib.rs:186-207`:

```json
{
  "version":   "0.7.3",              // string, REQUIRED. Sent to peers in hellos; peers only accept 1–24 chars, starting with a digit, [A-Za-z0-9.-] (session.rs:2580-2585)
  "state_dir": "/data/user/0/<pkg>/files/kyokai",   // path, REQUIRED. Created if missing (lib.rs:832)
  "profile":   "",                   // string, optional (default ""). Desktop: keys the OS credential entry. Android: unused by the store
  "agent":     null,                 // path, optional. Privileged-helper only — NEVER set on Android
  "master_key": "<base64 of 32 bytes>" // Android only (#[cfg(target_os="android")]), optional
}
```

What the engine passes (`internal/engine/engine.go:110`): `{"version", "state_dir", "profile"}`
(+ `"agent"` in helper mode, `engine.go:111-123`). Go's Config: `internal/core/core.go:82-92`.

### Android-specific (`core/kyokai-core/src/android/mod.rs`, store.rs diff)

- `master_key`: base64 (standard alphabet) of exactly 32 bytes; anything else → start fails with
  `"bad master key"` (`android/mod.rs:23-33`). `build()` stores it (`lib.rs:835-838`), and the
  Android `store::os::master_key` takes it **once** (`android/mod.rs:36-38`, `store.rs:617-631`).
  - Given → secrets are written encrypted to `<state_dir>/secrets.bin` → `status.persistence = "os-store"`.
  - Absent → `"memory-only"`: identity, saved passwords, networks, keys are lost at exit.
  - Given but different from the key that wrote `secrets.bin` → `"unreadable"` (memory only this run;
    file untouched) (`store.rs:59-82`).
  - The app must generate a random 32-byte key once, keep it wrapped by the Android Keystore, and
    pass the same key every start.
  - GOTCHA: `identity.reset/import` and `store.import` rebuild via `build()` which re-applies
    `cfg.master_key` (fine). But `store.start_over` and `permission.request {"name":"keychain"}`
    rebuild via `rebuild_on_store` → `store::open` directly (`lib.rs:946-973`), after the key was
    already taken → the rebuilt store is **memory-only**. Restart the core (`kyokai_stop` +
    `kyokai_start`) instead of relying on those on Android.
- `android.clipboard` `{"text": string}` → `null`: what the person copied on the phone, offered to
  hosts by sessions with `clipboard` (`lib.rs:1553-1557`, `android/mod.rs:41-46`). Text only;
  host→phone text arrives only as media packet 13 (the core does not write the phone clipboard;
  `android/mod.rs:60-86`).
- `android.decoders` `{"decode": ["h264","hevc","vp9","av1","vp8"]}` → `null`: codecs the app
  decodes with MediaCodec; used from the next session on (`lib.rs:1561-1566`,
  `video.rs` android `decodable` returns `(android::decoders(), [])` — no 4:4:4). Must be called
  before `session.connect`, else the controller announces no codecs. Codec names are the core's
  (`video.rs:577`: `h264, hevc, vp9, vp9-sw, av1, vp8`).
- Capture on Android always yields the "cannot-capture" placeholder; no displays; no power/sleep
  watch; no helper/agent (`video.rs`, `power.rs`, `agent.rs` diffs). Android is controller-only.
- `about` on Android: `os` is `""`, name/maker/model empty (`about.rs:150-219` only fills
  Windows/macOS) → call `device.set_name` with something like the phone's model so hosts see a name.

### What `kyokai_start` does (`lib.rs:816-877`)

Creates `state_dir`, opens the store, loads-or-creates the Ed25519 identity (Device ID), creates the
AI state, loads access state, **starts the network runtime and joins every saved, joined network**
(`net::Network::start`, `lib.rs:864`), generates a temporary password. It returns the status.

### What the engine does around it that a direct caller must do itself

| Engine behaviour | Where | Direct caller (Android) |
|---|---|---|
| ABI check before start | `core.go:187` | `kyokai_abi_version()==8` |
| `host.serve` after start: `"all"` in user mode (`"none"/"unattended"` only for the helper without a GUI) | `engine.go:149`, `updateServe` `engine.go:995-1010` | Default inside the core is already `Serve::All` (`access.rs:97-107`), i.e. **the phone accepts incoming host sessions from its networks**. A controller-only app should call `host.serve {"serve":"none"}` once after start — refuses every login (`absent`) and ends host sessions (`lib.rs:1499-1510`). |
| Status producer: re-reads `status` 100 ms after each command and every 500 ms, pushes to the GUI | `engine.go:900-950` | Poll `status` yourself (e.g. every 500 ms while visible, plus right after each command). Network views inside the core refresh every 2 s. |
| `logs.set` → core `access.history {"keep": !logs_off}` | `engine.go:432-448` | Optional: `access.history {"keep": bool}` — whether known hosts / trusted devices are persisted (default: kept). |
| GUI sends `capture.show`, `input.kyokai`, `sound.source` on attach | `internal/gui/app.go:327-380` | Host-only; skip. |
| `session.media` stream only for a session with `role=controller` and state `connected`/`reconnecting` | `engine.go:784-791` | Same rule before `kyokai_media_read`. |
| `tunnel.open` loop: open → `tunnel.wait` 1 s at a time up to 90 s → pump → `session.close` | `engine/services.go:130-164` | Do exactly this (section 7). |
| `sessions.close_controllers` 15 s after the last GUI detached (helper only) / on GUI quit | `engine.go:975-989`, `gui/closing.go:243` | On app exit call `kyokai_stop()` (says goodbye to every session). |
| Persisting | — | Nothing to persist outside the core: it writes `secrets.bin`, `device.json`, AI history itself into `state_dir`. Persist only the master key (Keystore) and UI-only prefs. |
| Timers the GUI runs | `gui/home.go:30-31,232`, `gui/routes.go:18,309` | Renew `watch.set` at least every 10 s (lease is 30 s); `routes.probe` every 60 s while the device list shows. |

Typical start order for Android:
```
kyokai_abi_version()                          -> 8
kyokai_start({"version":"0.7.3","state_dir":…,"master_key":…})   -> status
call android.decoders {"decode":[…MediaCodec-supported…]}
call host.serve {"serve":"none"}
call device.set_name {"name":"Pixel 9"}        (once, if status.name == "")
loop: status (500 ms), watch.set (≤10 s), routes.probe (60 s)
```

---

## 2. `status` — full result shape

Built in `lib.rs:1945-2007` (Go mirror types: `internal/localapi/protocol.go:998-1070`; core raw
decode `internal/engine/engine.go:1022-1055`). `params` ignored. Never contains a secret.
If the core is not started, `kyokai_call status` still returns `ok:true` with
`result = {"error":"the core is not started"}` (`lib.rs:2002`, test at `lib.rs:2142-2143`).

| Field | Type | Meaning / source |
|---|---|---|
| `version` | string | the `version` passed at start |
| `abi` | int | 8 |
| `device_id` | string | this device's 9-digit Device ID |
| `fingerprint` | string | identity fingerprint |
| `state_dir` | string | |
| `persistence` | `"os-store"\|"memory-only"\|"unreadable"\|"denied"` | `store.rs:26-40` |
| `password_serial` | u64 | changes with the temporary password (host) |
| `network` | NetworkStatus | below |
| `permanent_password` | bool | host |
| `password_grants` | [permission] | host |
| `password_mode` | `"temporary"\|"permanent"\|"both"\|"none"` | host |
| `without_asking` | bool | host |
| `service_ports` | `{ssh,rdp,vnc}` | host |
| `nanokvm` | null on Android | host (`lib.rs:1930-1940`) |
| `by_address` | `{on, ranges[], port\|null, error\|null}` | host listener (`net.rs:1013-1021`) |
| `keeps_history` | bool | `access.history` |
| `protected` | bool | host protected mode |
| `ai` | `{id,state,paused?,origin?}` \| null | THIS device's own running AI task (host) |
| `ai_draft` | string | THIS device's shared AI draft (host) |
| `requests` | [HostRequest] | incoming confirmations to answer (host; empty with `serve:none`) |
| `sessions` | [Session] | **controller sessions live here** — below |
| `watching` | [Watched] | live stats of hosts you watch — below |
| `watchers` | [`{device_id, about, since}`] | devices watching THIS one (host) |
| `recent` | [Recent] | **known hosts (your device list)** — below |
| `name` | string | friendly name chosen here (`""` = computer's name) |
| `publish_name` | bool | name shown in networks pre-login |
| `serve` | `"all"\|"unattended"\|"none"` | |
| `about` | About | what this device tells peers: `{name, maker, model, os}` |
| `permissions` | null (macOS only object) | `lib.rs:2027-2052` |

### `network` (NetworkStatus) — `net.rs:659-735`, doc `doc/en-us/networking.md` "Status"

Aggregate of all networks plus `networks[]` (one per kept profile):
```json
{
  "state": "off|connecting|online|error",
  "error": "…",                      // only for state=error
  "address": "10.126.126.5",          // virtual IPv4 (first online network)
  "nat": "unknown|open|no-pat|full-cone|restricted|port-restricted|symmetric|symmetric-easy|symmetric-firewall",
  "listen_port": 11010,               // only when direct paths listen
  "devices": [                        // Kyokai peers the networks route to (announced IDs — hints, not proof)
    {"device_id":"482916735","path":"direct|relay","latency_ms":23,"name":"NUC"?,"lan":true?}
  ],
  "unreachable": "…"?,                // official EasyTier core only
  "networks": [
    {"id":"9f2c…(16 hex)","label":"Home","joined":true,"state":"online","address":"…","nat":"…",
     "listen_port":…,"devices":[…]}   // state "off" when not joined
  ]
}
```

### `sessions[]` — `session.rs:1590-1615` (Go `SessionInfo`, `protocol.go:838-860`)

Watch sessions (`see-status`) are hidden. Up to 8 finished sessions are kept (`session.rs:133`).
```json
{
  "id": 7,                            // u64: the session id for media/close
  "role": "controller|host",
  "device_id": "482916735",           // the other device
  "state": "connecting|confirming|connected|reconnecting|closed|failed",   // session.rs:842-853
  "failure": null | "unreachable"|"wrong-device"|"key-changed"|"incompatible"|"broken"|"unsupported"
             | {"refused":"password|denied|timeout|busy|rate-limited|absent|service-down"},  // session.rs:809-828, access.rs:79-93
  "granted": ["view-screen","control-input",…],   // what the host granted
  "peer_version": "0.7.3",
  "peer_source": "https://github.com/YuanZhe-99/Kyokai",
  "peer": {"name":"NUC","maker":"Intel","model":"NUC11","os":"windows"},  // the host's claim, after login
  "service": null | "ssh"|"rdp"|"vnc"|"nanokvm",    // tunnel kind; null = desktop/AI session
  "route": "" | "192.168.1.20:47310" | null        // controller only: "" = over the Kyokai network, else the address; null for host role
}
```
There is **no codec/fps/bitrate in the status**: those come as media packets 1 (`video-start`) and
4 (`stats`) on the session (section 8).

### `recent[]` — the known hosts ("device list"), newest first (`lib.rs:1973-1995`)
```json
{
  "device_id": "482916735",
  "last": 1762665600,                 // unix s of last accepted session
  "about": {"name","maker","model","os"},
  "saved_password": true,
  "routes": [ {"address":"192.168.1.20","added":1762000000,"last_ok":1762665600,"rtt_ms":3,"kbps":24000,"fails":0,
               "probe": null | {"address":"192.168.1.20","rtt_ms":2?,"state":"ok|unreachable|other-device|incompatible|broken","at":1762665601234}} ],
  "network_route": {"last_ok":…,"rtt_ms":…,"kbps":…,"fails":…},   // how the Kyokai network route went
  "prefer": "" | "network" | "<one of routes[].address>",       // "" = Auto
  "features": ["key-login","tunnel","status","input-sync","wake","recovery","nanokvm","resolution","move","ai-sessions","custom-quality","lock-after"?],
  "saved": {"password":bool,"key":bool,"ssh":bool,"rdp":bool,"vnc":bool}
}
```
`routes_json`: `lib.rs:2011-2022`; `Probe`: `net.rs:1683-1697`; features: `session.rs:35-84`.
Online-ness of a recent host = it appears in `network.devices` (by Device ID) or a route probe is
`ok`, or `watching[].state == "watching"`.

### `watching[]` — live host stats (`watch.rs:391-410`; Go `protocol.go:1297-1375`)

Only while a `watch.set` lease holds (30 s), at most 8 hosts.
```json
{
  "device_id": "482916735",
  "state": "connecting|watching|no-credential|unsupported|refused|offline",   // watch.rs:224-236
  "sample": null | {
    "at": 1762665601000, "uptime_s": 86400,
    "cpu": {"usage": 12.5, "cores": 16, "user": 8.1, "system": 4.4},
    "memory": {"used": 8589934592, "total": 34359738368},
    "gpu": {"usage": 3.0} | null,
    "disk": {"used": …, "total": …},
    "disk_io": {"read_bps": …, "write_bps": …} | null,
    "net": {"rx_bps": …, "tx_bps": …, "rx_total": …, "tx_total": …},
    "battery": {"percent": 80, "charging": true} | null,
    "services": ["ssh","rdp","vnc"],          // answering on the host's loopback
    "offers": ["view-screen","control-input",…],  // what your password/key grants without asking
    "ai": true,                               // host AI can start a task
    "nanokvm": false
  },
  "received_at": 1762665601050               // unix ms here; never show an old sample as live
}
```
`no-credential` = no saved password and no admitted key (nothing dialed) — watching needs one.

### Realistic example (controller phone with one desktop session and one SSH tunnel)

```json
{
  "version":"0.7.3","abi":8,"device_id":"731045288","fingerprint":"SHA256:3q…","state_dir":"/data/user/0/app/files/kyokai",
  "persistence":"os-store","password_serial":1,
  "network":{"state":"online","address":"10.144.144.7","nat":"port-restricted",
    "devices":[{"device_id":"482916735","path":"direct","latency_ms":18,"name":"NUC"},
               {"device_id":"905113402","path":"relay","latency_ms":96}],
    "networks":[{"id":"5b1e0c9d2a7f4e31","label":"Home","joined":true,"state":"online","address":"10.144.144.7","nat":"port-restricted",
                 "devices":[{"device_id":"482916735","path":"direct","latency_ms":18,"name":"NUC"},{"device_id":"905113402","path":"relay","latency_ms":96}]}]},
  "permanent_password":false,"password_grants":["view-screen","control-input","clipboard","files","hear-sound","see-status"],
  "password_mode":"both","without_asking":true,"service_ports":{"ssh":22,"rdp":3389,"vnc":5900},"nanokvm":null,
  "by_address":{"on":false,"ranges":[],"port":null,"error":null},"keeps_history":true,"protected":false,
  "ai":null,"ai_draft":"","requests":[],
  "sessions":[
    {"id":3,"role":"controller","device_id":"482916735","state":"connected","failure":null,
     "granted":["view-screen","control-input","clipboard","hear-sound"],"peer_version":"0.7.3",
     "peer_source":"https://github.com/YuanZhe-99/Kyokai","peer":{"name":"NUC","maker":"Intel","model":"NUC11PAHi7","os":"windows"},
     "service":null,"route":""},
    {"id":4,"role":"controller","device_id":"482916735","state":"connected","failure":null,"granted":["use-ssh"],
     "peer_version":"0.7.3","peer_source":"https://github.com/YuanZhe-99/Kyokai","peer":{"name":"NUC","maker":"Intel","model":"NUC11PAHi7","os":"windows"},
     "service":"ssh","route":""},
    {"id":2,"role":"controller","device_id":"905113402","state":"failed","failure":{"refused":"password"},"granted":[],
     "peer_version":"0.7.2","peer_source":"https://github.com/YuanZhe-99/Kyokai","peer":{"name":"","maker":"","model":"","os":""},"service":null,"route":""}
  ],
  "watching":[{"device_id":"482916735","state":"watching","received_at":1762665601050,
    "sample":{"at":1762665601000,"uptime_s":86400,"cpu":{"usage":12.5,"cores":16,"user":8.1,"system":4.4},
      "memory":{"used":8589934592,"total":34359738368},"gpu":{"usage":3.0},"disk":{"used":250000000000,"total":1000000000000},
      "disk_io":{"read_bps":120000,"write_bps":40000},"net":{"rx_bps":5000,"tx_bps":3000,"rx_total":9000000000,"tx_total":1200000000},
      "battery":null,"services":["ssh","rdp"],"offers":["view-screen","control-input","clipboard","files","hear-sound","see-status"],"ai":true,"nanokvm":false}}],
  "watchers":[],
  "recent":[{"device_id":"482916735","last":1762665500,"about":{"name":"NUC","maker":"Intel","model":"NUC11PAHi7","os":"windows"},
    "saved_password":true,"routes":[{"address":"192.168.1.20","added":1762000000,"last_ok":1762600000,"rtt_ms":3,"kbps":24000,"fails":0,
      "probe":{"address":"192.168.1.20","rtt_ms":2,"state":"ok","at":1762665590000}}],
    "network_route":{"last_ok":1762665500,"rtt_ms":18,"kbps":12000,"fails":0},"prefer":"",
    "features":["key-login","tunnel","status","input-sync","wake","recovery","nanokvm","resolution","move","ai-sessions","custom-quality","lock-after"],
    "saved":{"password":true,"key":false,"ssh":true,"rdp":false,"vnc":false}}],
  "name":"Pixel 9","publish_name":false,"serve":"none","about":{"name":"Pixel 9","maker":"","model":"","os":""},"permissions":null
}
```

---

## 3. Connecting as a controller

### `session.connect` (`lib.rs:104-131` struct, `lib.rs:1181-1227` handler)

Params:
```json
{
  "device_id": "482916735",   // REQUIRED, exactly 9 ASCII digits
  "password": "",             // REQUIRED field (string; may be ""). "" = use the saved password for this host if any
  "want": ["view-screen","control-input","clipboard","files","hear-sound"],   // optional, default []
  "remember": false,          // save the password after a login the host accepts with it
  "address": "192.168.1.20",  // optional: dial this IP/domain[:port] ALONE (default port 47310); device there must prove to be device_id; added to routes
  "route": "auto",            // optional: "auto" | "network" | one of the host's addresses; absent = the host's `prefer`
  "nanokvm": false,           // the computer wired to the host's NanoKVM USB (want then ["use-nanokvm"])
  "take_over": false          // only for this device's OWN NanoKVM (not on Android)
}
```
Note: `password` has no serde default (`lib.rs:117`) — **omitting it is an error**
(`"bad connect request: missing field `password`"`). Always send `"password": ""`.

Result: `{"id": <u64 session id>}` immediately; progress shows in `status.sessions[id]`.

Kinds — there is no `kind` field. What you get is chosen by `want` / `nanokvm`, or by a different method:
| You want | Call |
|---|---|
| desktop (video+input+sound+clipboard) | `session.connect`, `want` from `view-screen, control-input, clipboard, files, hear-sound` (GUI's `desktopWant`, `gui/sessions.go:293`) |
| AI only (no picture) | `session.connect`, `want: ["run-ai-task","approve-ai-action"]` (GUI `aiWant`, `gui/ailink.go:37`) |
| NanoKVM of a host | `session.connect`, `nanokvm:true`, `want:["use-nanokvm"]` |
| SSH / RDP / VNC | `tunnel.open` (section 7) — a separate session per tunnel |
| files over SSH (SFTP/SCP) | an SSH tunnel; the client speaks SFTP itself |
| quiet stats | `watch.set` (core opens hidden `see-status` sessions itself) |

Permission names (`access.rs:17-42`, kebab-case): `view-screen, control-input, run-ai-task,
approve-ai-action, clipboard, files, hear-sound, see-status, use-ssh, use-rdp, use-vnc, use-nanokvm`.
None implies another. (`files` = files through the clipboard; Android's clipboard handles text
only, `android/mod.rs:74-85`, so asking for `files` brings nothing on Android.)

Synchronous errors (`ok:false`): `"bad connect request: …"`, `"a Device ID has 9 digits"`,
`"that is this device's own ID"`, `"the core is not started"`, `"not connected to a network"`
(Auto/network route with no joined network running and no known address, `net.rs:2131-2147`), a bad
`address` (`net::split_address`).

### Authentication flow (what the core does for you)

Docs: `doc/en-us/identity-and-access.md` (Passwords, Saved passwords, Keys, Admission); handshake
`session.rs:1-4,135-246`.

1. Noise XX handshake proves both device keys. First accepted session **pins** the host key for
   that Device ID; a later different key → `failure: "key-changed"` (forget with `host.forget`).
   Host key not deriving the dialed ID → `"wrong-device"`.
2. Credentials offered automatically by the core:
   - **Password** (OPAQUE, both slots — temporary and permanent — tried in one round; the
     controller never learns which slot matched): the typed `password`, else the saved one.
   - **Ed25519 sign-in keys** from `keys.list` (type `ed25519` only, ≤8), the key the host admitted
     last first; only to hosts announcing `key-login`; never on resume. Unknown/off keys are ignored.
   - Neither → "ask without a password": the host's user sees a confirmation (60 s).
3. Host decides (Admission table in identity-and-access.md:82-95): accepted password/key within
   password grants + "Connect without asking" → admitted at once; asking for more (e.g. AI
   permissions, services) → host user confirms; nobody to confirm → `absent`.
4. `remember:true` saves the password only when the host admitted **with that password**. A saved
   password the host refuses is forgotten automatically (`session.rs:1170-1180` `Remember`).
   The key the host admitted is remembered (`recent[].saved.key`).

There is no "password required" event. The GUI learns it from the session state
(`gui/viewer.go:1740-1800`):
- `state == "confirming"` → the host user is being asked. GUI shows the password box
  ("or type the password"). Typing one = **close this session and connect again** with the password
  (`viewer.redial`, `gui/viewer.go:573-620`: `session.close {id: old}` then `session.connect`).
- `state == "failed"` → show why (`gui/sessions.go:452-490`) and the password box again:
  `{"refused":"password"}` wrong password (or denied ask counted as failed login),
  `{"refused":"denied"}`, `"timeout"` (60 s no answer), `"busy"` (>4 confirmations open),
  `"rate-limited"`, `"absent"` (nobody to confirm / host serves no one), `"unreachable"`,
  `"wrong-device"`, `"key-changed"`, `"incompatible"` (version), `"broken"`, `"unsupported"`.
- `state == "connected"` → `granted` lists what you got; open media.
- `state == "reconnecting"` → the core is resuming automatically (resume token; route may
  change); keep the media reader; input is refused meanwhile (packet 15 `{"paused":true}`).
- `state == "closed"` → ended normally.

Order the GUI uses for a desktop tab (`gui/viewer.go:383-426, 573-620, 803-826`):
```
[optional, by address] session.identify {"address"} -> {"device_id"} | {"failure"}
session.connect {device_id, password:"", want:desktopWant, remember:false, address?}
poll status until sessions[id].state in {connected, failed, closed}  (show box while confirming/failed)
on connected: kyokai_media_read loop; first write [3]{"type":"key-frame"}, then quality/codec/audio/clipboard-use choices
on close: session.close {id}
```

### `session.identify` (`lib.rs:1388-1405`)
Params `{"address": "host[:port]"}` (validated, port default 47310). Dials **without** the core
lock (blocks seconds). Result: `{"device_id":"482916735"}` or
`{"failure":"unreachable"|"incompatible"|"broken"|"self"}` (`ok:true` in both cases).
GUI then calls `session.connect` with that `device_id` and `address` (`gui/sessions.go:236-260`).

### `session.close` (`lib.rs:1487-1490`)
`{"id": u64}` → `{}`. Error `"no such session"` (`session.rs:1560-1569`). Says goodbye; the
session shows `closed` in the status for a moment. Works in any state (also cancels a dial or a
pending confirmation).

### `permission.request` — NOT a session thing
`{"name": "screen"|"accessibility"|"input-monitoring"|"keychain"}` → `{"granted": bool}`; macOS
privacy prompts (`lib.rs:1589-1592, 2059-2075`). Elsewhere: `"this system asks for no permissions"`
except `keychain` (re-opens the store; see the Android gotcha in §1). Skip on Android.

There is **no `permissions` method**. Session permissions are `want` → `sessions[].granted`.
`access.password_grants` / `access.settings` / `request.decide` are host-side.

---

## 4. Networks

Docs: `doc/en-us/networking.md` (Settings, Direct paths, Routes, Status). Up to 8 networks, each
≤8 server URLs (`tcp, udp, ws, wss, quic, wg`; `faketcp` refused), network name ≤64 chars,
secret (<16 chars reported weak), optional label ≤64. All joined networks run at once.
Settings live in the secrets store (memory-only without a master key!).

### `network.profiles` (`lib.rs:1138`, `net.rs:474-499`) — params none
```json
{"direct": false, "latency_first": false, "easytier": null,
 "profiles":[{"id":"5b1e0c9d2a7f4e31","label":"Home","servers":["tcp://public.easytier.cn:11010"],
   "name":"my-net","has_secret":true,"weak_secret":false,"joined":true,"toml":"","options":[]}]}
```

### `network.profile.set` (`lib.rs:1139-1146`, `net.rs:181-200`) → same as `network.profiles`
```json
{"id": "…"?, "label": "Home"?, "servers": ["tcp://…:11010"]?, "name": "my-net"?, "secret": "…"?, "joined": true?, "toml": "…"?}
```
No `id` = add (servers + name required; joined unless `joined:false`). With `id` = change; omitted
fields (secret too) keep their value. Joining two networks with the same name+secret is refused.
Errors are reasons (strings). Engine: `engine.go:325-334`.

### `network.profile.remove` `{"id": "…"}` → profiles (`lib.rs:1147-1153`)

### `network.direct` `{"direct": bool}` → profiles (`lib.rs:1174-1180`)
Try hole-punched/UPnP direct paths in every network (opens a listen port).

### `network.latency_first` `{"latency_first": bool}` → profiles (`lib.rs:1154-1162`)

### `network.backend` `{"easytier": null | "<tag>"}` → profiles (`lib.rs:1163-1173`)
Official EasyTier core binary (downloaded by the engine's `cores.*`, not in the core) — **skip on
Android**; keep `null` (embedded node).

### `network.get` / `network.set` — legacy single-network API (`lib.rs:1127-1135`, `net.rs:161-178,461-471`)
get → `{"servers":[…],"name":"…","has_secret":bool,"weak_secret":bool,"direct":bool}`;
set `{"servers"?, "name"?, "secret"?, "direct"?}` (missing secret keeps it; empty clears; no servers
+ no name removes) → the same shape. Prefer the profile API.

### `routes.set` (`lib.rs:1268-1299`) — a known host's addresses & route choice
```json
{"device_id":"482916735", "add":"192.168.1.20[:port]"?, "remove":"192.168.1.20"?, "prefer":""|"network"|"<address>"?}
```
→ `{"routes":[…as recent[].routes…], "prefer":"…"}`. `add` also starts a probe. Max 8 addresses.
Errors: unknown host, bad address. (`gui/routes.go:158-160`)

### `routes.probe` `{"devices":["482916735",…]}` (≤16) → `{}` (`lib.rs:1302-1312`)
Looks at the addresses in the background (TCP RTT + hello); results appear in
`recent[].routes[].probe`. GUI: every 60 s while Home shows (`gui/routes.go:18,293-310`).

Route semantics: `route` on connect/tunnel overrides; Auto ranks network vs addresses with happy
eyeballs (networking.md:112-147). `sessions[].route` shows the one in use.

---

## 5. Devices & credentials

| Method | Params | Result | Notes |
|---|---|---|---|
| `device.set_name` (`lib.rs:1105-1126`) | `{"name": string?, "publish": bool?}` (either/both; `null`/absent keeps) | `{"name","publish","about":{name,maker,model,os}}` | ≤64 chars (`about::MAX_NAME`); `""` follows the computer's name (empty on Android). `publish` puts the name in `host_hello` for anyone (host-ish) |
| `device.remove` (`lib.rs:1423-1435`) | `{"device_id"}` | `{}` | Ends this device's sessions with it, unlists them, forgets saved password + `saved.*` + pinned key (removes from `recent`) |
| `host.forget` (`lib.rs:1653-1659`) | `{"device_id"}` | `{}` | Forget only the pinned host key — the fix for `key-changed` (GUI menu "Forget identity", `gui/home.go:976-979`). Error `"not a known host"` |
| `password.forget_saved` (`lib.rs:1438-1441`) | `{"device_id"}` | `{}` | Forgets password + key + services' sign-ins (everything saved) |
| `credentials.get` (`lib.rs:1353-1359`) | `{"device_id","service":"ssh"\|"rdp"\|"vnc"}` | Credentials (below) or `{}` | Includes the password. Owner-only in the engine |
| `credentials.set` (`lib.rs:1360-1371`) | `{"device_id","service","credentials":Credentials}` | `{}` | Replaces; a password or host_key left out stays; empty password removes it |
| `credentials.forget` (`lib.rs:1374-1387`, `access.rs:1326-1340`) | `{"device_id","service"?}` | `{}` | `service`: `"ssh"\|"rdp"\|"vnc"` one service; `"key"` the admitted key; `"password"` the Kyokai password; absent/`""` everything |
| `keys.list` (`lib.rs:1442`, `keys.rs:209-214`) | — | `[{"id","name","type","public","added"}]` | this device's sign-in keys; `type`: `ed25519\|rsa\|ecdsa-p256\|ecdsa-p384`; `id` = first 16 hex of SHA-256(pub) |
| `keys.add` (`lib.rs:1443-1449`, `keys.rs:222-249`) | `{"name": string?, "private": "<base64>"}` | `{"id","name","type","public","added"}` | private = Ed25519 **32-byte seed** or PKCS#8 DER (RSA≥2048, ECDSA P-256/384), base64. Max 16 keys. GUI generates Ed25519 in Go and sends the seed (`gui/keys.go:400-430`) — do the same in Dart |
| `keys.remove` (`lib.rs:1450-1453`) | `{"id"}` | `{}` | `"no such key"` |
| `keys.sign` (`lib.rs:1454-1466`, `keys.rs:331+`) | `{"key_id","algorithm","data":"<base64>"}` | `{"signature":"<base64>"}` | see §7 |
| `trusted.list` / `trusted.remove` (`lib.rs:1632-1652`) | — / `{"key"}` | `[{"key","device_id","first","last","granted","about"}]` | **host-only** (controllers this device admitted) — skip |
| `authorized.list/add/set/remove` (`lib.rs:1467-1486`) | | | **host-only** (keys that may log in to THIS device). Use only if you want to show the phone's public key for pairing: the GUI "pair" flow adds a key to the *host's* `authorized.add` on the host computer. Skip on the phone |
| `identity.export` (`lib.rs:1038-1045`) | `{"passphrase"}` (≥10 chars) | `{"document":"…"}` | Argon2id, slow |
| `identity.import` (`lib.rs:1046-1055`) | `{"document","passphrase"}` | `{"device_id"}` | rebuilds core: ends sessions, reconnects network |
| `identity.reset` (`lib.rs:1056`) | — | `{"device_id"}` | new identity |
| `store.export` / `store.import` / `store.clear` / `store.start_over` (`lib.rs:1059-1104,1519`) | | | run-mode moves between desktop engines; `store.start_over` `→{"kept":bool}` (see Android gotcha) — skip unless you build backup/restore |
| `access.history` (`lib.rs:1419-1422`) | `{"keep": bool}` | `{}` | keep known hosts/trusted devices in the store, or memory only |

`wake` is **not a method**: it is a session action `{"type":"action","action":"wake"}` sent on a
connected desktop session (to hosts with feature `wake`; older ones get a Shift tap,
`session.rs:4600-4606`; GUI `gui/viewer.go:1949`). There is no Wake-on-LAN.

Credentials object (`access.rs:519-537`, Go `protocol.go:317-332`):
```json
{"method":"key|password|account|none"?, "user":"me"?, "domain":"CORP"?, "password":"…"?, "key_id":"a1b2c3d4e5f60718"?, "host_key":"ssh-ed25519 AAAA…"?}
```
(empty fields omitted; `method` = how the client signs in, remembered with "Remember").

---

## 6. AI tasks from the controller side

**Important:** the `ai.task.*`, `ai.tasks`, `ai.settings.*`, `ai.key.set`, `ai.models.list`,
`ai.scope.set`, `ai.folders.set`, `ai.beside.set`, `ai.apps`, `ai.draft.set`, `ai.history.clear`,
`ai.stop`, `ai.pane.*` methods (`lib.rs:1660-1838`) all act on **this device's own AI** (AI runs on
the host). A controller drives the **remote host's** AI through **control messages on a
session's media channel**, never through `kyokai_call`. `ai.pane.answer` is unrelated to approvals
(it relays a GUI-served RDP/VNC pane to the local AI). The local `ai.task.decide` exists
(`lib.rs:1791-1803`) but approves the local host's own task.

### Setup (GUI `gui/ailink.go`)
1. `session.connect {"device_id", "password":"", "want":["run-ai-task","approve-ai-action"]}`
   (`ailink.go:138-160`). AI permissions are not in default password grants, so the host user is
   usually asked (state `confirming`). The host sends no picture for this session.
   (You can also add these two permissions to a desktop session's `want`; the GUI uses a separate
   "AI link" session per host.)
2. When `connected`: `run = granted ∋ run-ai-task`, `approve = granted ∋ approve-ai-action`
   (`ailink.go:203-207`). Start `kyokai_media_read` on the session (`ailink.go:222-258`).
3. The host pushes (every 400 ms check, only on change, and on (re)connect; `session.rs:4214-4229`):
   packet 5 with the host's **latest task** (whoever started it — one record for all controllers)
   and packet 10 with the shared draft. Requests go as packet `[3]` + JSON (`ailink.go:331-338`).

### Controller → host control messages (`session.rs:320-369, 489-508`; handler `session.rs:3207-3248`)

All written with `kyokai_media_write(session, [0x03] + utf8(json))`:

| Message | Needs | GUI |
|---|---|---|
| `{"type":"ai-start","key":"<idempotency key>","instruction":"…","thinking":"low\|medium\|high\|max"?}` | `run-ai-task` | `aisession.go:637-642` (key = `strconv.FormatInt(time.Now().UnixNano(),36)`) |
| `{"type":"ai-command","id":<task id>,"command":"pause"}` / `"resume"` / `"cancel"` | `run-ai-task` | `aisession.go:672-679` |
| `{"type":"ai-command","id":N,"command":"reply","text":"…","thinking":"…"?}` | `run-ai-task` | `aisession.go:609-614` |
| `{"type":"ai-command","id":N,"command":"fork","run":<usize>?}` (no run = clone as is) | `run-ai-task` + host feature `ai-sessions` | `ai.go:356-360` |
| `{"type":"ai-command","id":N,"command":"compact"}` | same | `aiview.go:813` |
| `{"type":"ai-command","id":N,"command":"rename","text":"name"}` (`""` gives back the instruction's name) | same | `aisession.go:715` |
| `{"type":"ai-command","id":N,"command":"export"}` → answered by packet 16 | same | `ailink.go:349-358` |
| **Approval:** `{"type":"ai-decide","id":N,"approve":true\|false}` | `approve-ai-action` | `aisession.go:685-692` |
| `{"type":"ai-draft","text":"…"}` (shared draft as you type) | `run-ai-task` | `ailink.go:341-346` |

Not permitted / failing → packet 6 `{"error":"this session may not do that"}` or the AI's own reason.
Pause from a controller is `Pause::Controller`; disconnecting pauses the task it started
(`paused:"disconnected"`), unless the session *moves* (resume with feature `move`).
Start is idempotent by `key`; nothing is replayed after a reconnect (the GUI drops queued requests,
`ailink.go:229-233`).

### Host → controller packets (from `kyokai_media_read`)

| Kind | Payload | Source |
|---|---|---|
| 5 `AI_TASK` | the task record (below) | `session.rs:4870-4876`, `ai/task.rs:1242-1256` |
| 6 `AI_ERROR` | `{"error":"…"}` (safe to show) | `session.rs:4884-4890` |
| 10 `AI_DRAFT` | `{"text":"…"}` | `session.rs:4787-4794` |
| 16 `AI_EXPORT` | `{"id":N,"markdown":"…"}` | `session.rs:4877-4883` |
| 9 `ACTIONS` | `{"ctrl_alt_del":bool,"blocked":bool,"privacy":bool}` — session actions the host offers (Windows hosts; desktop sessions with `control-input`) | `session.rs:5156-5162`, `session.rs:440-453` |

Task record (`ai/task.rs:400-500`, `record()` adds `resumable`, `ai/task.rs:3067-3073`; Go
`protocol.go:463-551`). In packet 5, `steps` and `runs` are trimmed to the last 20 and `progress`
to the last 3 (`SESSION_STEPS = 20`, `ai/task.rs:521`):
```json
{
  "id": 12, "instruction": "Open the quarterly report and export it as PDF",
  "origin": "731045288"?,                 // controller Device ID that started it; absent = host's own user
  "source": "claude", "model": "claude-opus-…", "thinking": "medium"?,
  "state": "running|approval|paused|done|failed|cancelled",
  "paused": "host-user|local-input|controller|take-over|disconnected|sleep|locked|folders|beside"?,
  "note": "…"?, "error": "…"?,
  "text": "model's latest text", "progress": ["…"],
  "steps": [{"at": 1762665601, "action": {"kind":"click", …} | null,
             "outcome": "ok|failed|declined|not-executed|paused", "detail": "…"?}],
  "approval": {"action": {"kind":"type", …}, "flagged": ["…"], "class": "terminal|password-vault|…"?}?,   // present while state=="approval"
  "created": 1762665500, "updated": 1762665601,
  "tokens": {"input": 12345, "cached": 10000, "output": 678},
  "name": "Q3 export"?, "runs": [{"message":"…","text":"…","first":0,"at":1762665500}],
  "context": 23456, "pane": {"id","name","kind"}?, "outside": ["C:\\…"]?, "compacting": true?,
  "resumable": false
}
```
Action JSON shapes: `core/kyokai-core/src/ai/action.rs` and `doc/en-us/computer-use.md`.
Approval flow: state becomes `approval` with `approval.action` → show it → send `ai-decide`.
Which tasks the controller started: compare `origin` with `status.device_id`.

---

## 7. Tunnels for SSH / RDP / VNC (and SFTP)

**The core exposes NO local TCP port.** Tunnel bytes flow through `kyokai_media_read/write` as
packet kind 14 (`media.rs:60-61`, `lib.rs:1843-1879`). If a Dart/Java client library needs a
socket, wrap it yourself (a `Socket`-like stream, or a 127.0.0.1 ServerSocket bridge in the app).

### `tunnel.open` (`lib.rs:1230-1263`)
```json
{"device_id":"482916735","service":"ssh|rdp|vnc","address":"…"?,"route":"auto|network|<addr>"?}
```
→ `{"id": <session id>}` at once. Uses the saved Kyokai password if any, else sign-in keys, else
asks the host user (`password: saved.unwrap_or_default()`, `want: [use-<service>]`). There is no
`password` param — to tunnel with a typed password, first make a desktop/AI connect with
`remember:true`, or rely on keys. Sync errors: as `session.connect` (no 9-digit check here).

### `tunnel.wait` (`lib.rs:1336-1352`, `session.rs:1355-1383`)
`{"id": u64, "timeout_ms": u64?}` (default/max 90000) → `{"state": "...", "failure": …}`. Returns
as soon as the state is neither `connecting` nor `confirming`, or the wait ran out. A session that
vanished → `{"state":"closed"}`.

### Engine's exact sequence (`internal/engine/services.go:130-185`) — replicate it
```
r = tunnel.open {device_id, service, address?}                 -> {id}
loop until deadline 90 s:
    w = tunnel.wait {id, timeout_ms: 1000}
    break unless w.state in {"connecting","confirming"}          (or user cancelled)
if w.state != "connected":
    reason = w.failure as string  | w.failure.refused  | ("closed" if state=="closed") | "timeout"
    session.close {id}; fail(reason)      // service-down, denied, unsupported, unreachable, password, busy, absent, …
pump until either side ends:
    read:  kyokai_media_read(id, buf, cap>=1+128 KiB, 500)  -> [14][bytes]   (-1 = keep waiting, -2 = ended)
    write: kyokai_media_write(id, [14]+bytes)  (core splits into 64 KiB pieces; blocks for room; -2 = ended)
finally session.close {id}
```
Engine buffer limits: `tunnelMax = 1 + 128 KiB` (`engine.go:751`); client pieces of 64 KiB
(`localapi/tunnel.go:20,111-126`). A tunnel with no peer frame for 60 s ends; with `move` on both
sides it survives route changes (remote-services.md:33-42). Refusal names:
remote-services.md:58-61.

### SSH client auth with Kyokai keys (`internal/gui/ssh.go`)
- `sshDial` (`ssh.go:136-205`): opens the tunnel, then runs `golang.org/x/crypto/ssh`
  `NewClientConn(tunnel, "localhost:22", cfg)` with exactly ONE method:
  - `method == "key"`: `PublicKeysCallback(engineSigners)` — every key from `keys.list`, parsed from
    its `public` line; RSA restricted to `rsa-sha2-512`, `rsa-sha2-256` (`ssh.go:96-115`).
  - otherwise password + keyboard-interactive answering with the same password once.
- Signing (`ssh.go:59-91`, `gui/remote.go:82-90`): the SSH library hands the signer the user-auth
  "data to sign" (RFC 4252 §7: `string session_id || byte 50 || string user || string "ssh-connection"
  || string "publickey" || bool TRUE || string algorithm || string public_key_blob`). The GUI calls
  ```json
  {"method":"keys.sign","params":{"key_id":"<keys.list id>","algorithm":"ssh-ed25519|rsa-sha2-256|rsa-sha2-512|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384","data":"<base64 of that exact blob>"}}
  ```
  → `{"signature":"<base64>"}`, which is the **SSH wire encoding of the signature**
  (`string format || string blob`) — unmarshal it as an `ssh.Signature`. The core verifies that
  `data` really is a public-key user-auth request for that very key and algorithm
  (`keys.rs:331-348`, `check_userauth`) — it is not a general signing oracle.
  For dartssh2: implement a custom `SSHKeyPair`/identity whose `sign()` calls `keys.sign` with the
  data blob it is given (ensure it is the full RFC 4252 blob, not a hash).
- Host key: pinned on first use in `credentials.host_key` (authorized_keys line); a different key
  is refused before any password is sent (`ssh.go:217-236`). After a successful sign-in the GUI
  saves `credentials.set {device_id, service:"ssh", credentials:{user, method, host_key, password?/key_id?}}`
  (`ssh.go:194-203`). At sign-in it reads saved values with `credentials.get` (`remote.go:61-67`).
- Files: `internal/gui/sshfiles.go` runs SFTP (fallback SCP) over the same SSH-over-tunnel; nothing
  extra in the core.
- RDP/VNC: the same tunnel; the GUI's built-in clients speak RDP/RFB over it; saved sign-ins via
  `credentials.*` (`rdp`: user/domain/password; `vnc`: user/password).

---

## 8. Everything else a controller touches, and what is host-only

### Media channel of a desktop session (packets via `kyokai_media_read/write`)
GUI order (`gui/viewer.go:803-826`, `viewerinput.go:430-455`): open → write `[3]{"type":"key-frame"}`
→ write choices: `quality`, `codec` (if not auto), `hardware` (if software), `lock-after`, `audio`,
`clipboard-use` → reader loop. The core itself sends `codecs` (from `android.decoders`) and
re-sends the viewer's last quality/codec/audio/lock-after on resume (`session.rs:3770-3795`).

Host → controller (`media.rs:27-68`, built at `session.rs:4630-4960,5156-5175`):
| Kind | Payload |
|---|---|
| 1 VIDEO_START | `{"codec":"h264\|hevc\|vp9\|av1\|vp8\|raw-rgba…","width","height","i444"?,"encoder"?,"hardware"?,"placeholder"?,"size"?}` (`media.rs:70-97`) |
| 2 FRAME | `[2][flags u8 (1=key)][pts u64 BE µs][bitstream]` (`session.rs:4633-4640`, `media.rs:22`) |
| 4 STATS | `{"delay_ms","fps","bitrate","encode_ms","frames","video":"live\|dark\|recovering\|placeholder"}` (every second) |
| 5/6/10/16 | AI (section 6) |
| 7 CURSOR | `{"x":0..1,"y":0..1,"visible":bool}` |
| 8 DISPLAYS | `{"list":[{"x","y","width","height","primary"}],"current":idx}` (only with ≥2 displays) |
| 9 ACTIONS | `{"ctrl_alt_del","blocked","privacy"}` |
| 11 CODECS | `{"codecs":["h264",…]}` — the host's offer for the codec menu |
| 12 AUDIO | `[12][Opus packet]` 48 kHz stereo |
| 13 CLIPBOARD | `{"from":"controller\|host","at":ms,"text"\|"png"\|"files"}` (`session.rs:1150-1169`) — copy `text` to the Android clipboard yourself |
| 15 INPUT | `{"paused":bool}` — input refused as behind |

Controller → host control JSON (only these pass, `session.rs:4535-4610`):
`key-frame`; `no-picture {for_ms, why:"waiting|decode-error|stale"}`; `input {event}` (event kinds
`pointer{action:move|down|up,button,x,y}`, `scroll{dx,dy}`, `key{key,down,mods{shift,ctrl,alt,meta}}`,
`text{text≤4096}`, `scan{code,down,caps,num}`, `sync{held}` — `input.rs:12-48,148-165,328-334`);
`display {index}`; `quality {preset:"best|balanced|speed|custom", fps, i444, size?, custom?}`;
`codec {codec:"auto"|offer}`; `audio {on}`; `lock-after {on}`;
`action {action:"lock|ctrl-alt-del|block|unblock|privacy-on|privacy-off|wake"}` (`session.rs:460-477`);
the AI messages; plus two kept on this side only: `hardware {on}` (re-announce codecs) and
`clipboard-use {share, front}`.

### Calls by name the user asked about
| Name | Exists? | What it is |
|---|---|---|
| `displays` | no method | packet 8 in, `{"type":"display","index":i}` out |
| `video.targets` | no | — |
| `wake` | no method | session action `wake` (§5) |
| `watch.set` (`lib.rs:1313-1333`) | **yes, controller** | `{"devices":[9-digit ids], "slow":[subset]?}` → `{}`; lease 30 s (`watch.rs:25`), first 8 only (`watch.rs:23,294`); `[]` ends watching; GUI renews every 10 s (`gui/home.go:30-31,217-238`) |
| `capture.show` (`lib.rs:1540`) | host-only | |
| `input.kyokai`, `kyokai.shown` | host-only | |
| `sound.devices`, `sound.source` | host-only | |
| `clipboard.mine` `{"digest": 64 lowercase hex}` → `null` (`lib.rs:1567-1571`) | either | "don't offer this clipboard text to sessions" (e.g. after copying a password from the app) |

### Host-only — skip in a controller-only app
`password.reveal`, `password.regenerate`, `password.set_permanent`, `protect.set`,
`access.settings`, `access.password_grants`, `request.decide`, `trusted.list`, `trusted.remove`,
`authorized.*`, `host.serve` (call once with `"none"` only), `sessions.close_controllers`,
`capture.show`, `input.kyokai`, `kyokai.shown`, `sound.source`, `sound.devices`,
`nanokvm.devices` (not compiled on Android), `permission.request` (macOS), `agent.serve`,
`agent.restart`, `store.export/import/clear/start_over`, `network.backend`, all local `ai.*`
methods (§6), `status.requests/watchers/ai/ai_draft/password_*`.

### Controller set (what Kyokai-Mobile needs)
`status`, `android.decoders`, `android.clipboard`, `host.serve` (once, `none`), `device.set_name`,
`network.profiles`, `network.profile.set`, `network.profile.remove`, `network.direct`,
`network.latency_first`, `session.identify`, `session.connect`, `session.close`, `tunnel.open`,
`tunnel.wait`, `watch.set`, `routes.probe`, `routes.set`, `device.remove`, `host.forget`,
`password.forget_saved`, `credentials.get/set/forget`, `keys.list/add/remove/sign`,
`identity.export/import/reset`, `access.history`, `clipboard.mine`; plus media packets for video,
input, clipboard and AI.
