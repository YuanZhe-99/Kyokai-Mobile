# Kyokai controller media API: reference for the Android client

Paths are relative to `third_party/kyokai/` unless they start with `android/` (the Kyokai-Mobile app).
`core/` means `core/kyokai-core/src/`. Line numbers are from the working tree on 2026-11-09. In that tree the core has uncommitted edits, and `core/android/` is untracked.

C ABI version is **8** (`core/lib.rs:73`, Go `internal/core/core.go:20`).

---

## 0. Corrections to the premise

- **The core has no `video.open`, `video.close`, `video.key`, `video.targets`, `audio.open/close`, `input.open/close/release` or `displays` method.** The only `kyokai_call` methods in this area are `session.connect`, `session.close`, `status`, `android.decoders`, `android.clipboard`, `input.kyokai`, `capture.show`, `sound.source` and similar (`core/lib.rs:975-1840`). Grepping for `"video.`, `"audio.`, `"input.` and `"displays"` finds only `input.kyokai`, which is a host-side setting.
- Media is implicit. Once a controller session is **connected**, its engine-side media queue exists. The controller engine sends its `codecs` itself, and the host opens video when those codecs arrive. Everything else is a **control JSON** written with `kyokai_media_write` (`3` + JSON), or happens automatically.
- `internal/gui/keys.go` is SSH key management, not the keyboard. `internal/gui/screen.go` is the RDP/VNC `remoteDesk`, not Kyokai media. Keyboard code is in `internal/gui/viewerinput.go` (≈689-1220) and `viewerwin.go`.

---

## 1. How a viewer session's media starts

### 1.1 Core calls

| Step | Call | Notes |
|---|---|---|
| a | `kyokai_call {"method":"android.decoders","params":{"decode":["h264","hevc"]}}` | **Android only, and must come before connect.** The comment says "named to hosts from the next session on" (`core/lib.rs:1558-1566`). It is stored in `core/android/mod.rs:18-58`. |
| b | `kyokai_call {"method":"session.connect","params":{device_id, password, want, remember?, address?, route?, nanokvm?, take_over?}}` → `{"id": u64}` | `core/lib.rs:1181-1227`; `Connect` struct at `core/lib.rs:104-131`. `device_id` must be 9 ASCII digits (`:1184`). An empty `password` uses the saved one (`:1197-1202`). |
| c | Poll `status` until `sessions[i].id == id && state == "connected"` | `status()` is at `core/lib.rs:1945`. `sessions` comes from `Sessions::list` (`core/session.rs:1592-1616`), with fields `id, role, device_id, state, failure, granted, peer_version, peer_source, peer{name,maker,model,os}, service, route`. The states are `connecting`, `confirming`, `connected`, `reconnecting`, `closed` and `failed` (`internal/localapi/protocol.go:844-846`). |
| d | Loop on `kyokai_media_read(id, buf, cap, timeout_ms)` | `core/lib.rs:309-337`. It returns the length, or **-1** on timeout, **-2** when the session ended or does not exist, or **-3** when the packet is larger than `cap`. A -3 packet is dropped: if it was a frame, ask for a key frame. Frames can be up to `MAX_FRAME_BYTES = 64 MiB` (`core/media.rs:24`). |
| e | `kyokai_media_write(id, ptr, len)` with `0x03` + JSON | `core/lib.rs:356-397`. It returns **0**, or **-1** for a malformed packet or a first byte other than 3 or 14, **-2** when there is no such session, or **-3** when the packet is refused. Input is refused at once while the gate is paused. Other messages are refused after waiting `CONTROL_WAIT = 200 ms` (`:401`). |
| f | `kyokai_call {"method":"session.close","params":{"id":id}}` | `core/lib.rs:1487-1490` |

`want` permission names are kebab-case (`core/access.rs:18-42`): `view-screen`, `control-input`, `clipboard`, `files`, `hear-sound`, `run-ai-task`, `approve-ai-action`, `see-status`, `use-ssh`, `use-rdp`, `use-vnc` and `use-nanokvm`. The desktop GUI asks for `[view-screen, control-input, clipboard, files, hear-sound]` (`internal/gui/sessions.go:293`).

### 1.2 What the engine does by itself (controller side)

- As the session starts it re-sends the viewer's remembered `quality`, `codec`, `audio` and `lock-after` choices for a resumed session. It then **sends `{"type":"codecs","decode":decodable().0,"i444":decodable().1}`** to the host (`core/session.rs:3770-3795`). On Android, `video::decodable` returns `(android::decoders(), [])` (`core/video.rs:730-736`), so full colour is never advertised.
- It acknowledges each frame (`received`) and reassembles chunks (`core/session.rs:4629-4647`).
- It asks for a key frame by itself when the GUI's queue overflowed (`waiting_for_key`; `core/session.rs:4394-4405`, `4640-4646`; `core/media.rs:303-353`).
- It pushes `INPUT {paused}` whenever the input gate changes (`core/session.rs:4375-4392`), and pushes `{"paused":true}` when the connection drops (`:5170-5178`).

### 1.3 What the host does

- The host waits up to `CODECS_WAIT = 1 s` for the controller's `codecs` (`core/session.rs:510-512`, `3686`).
  - If the codecs arrive, it picks a codec, sends `{"type":"codec-offer"}` (which becomes the `CODECS` packet) and opens video (`core/session.rs:4909-4933`).
  - If the wait times out, it uses `video::choose(&[],…)` (`:4287-4297`). That gives **H.264 on a Windows host, and nothing on a macOS or Linux host**, which then sends the `no-codec` placeholder (`core/video.rs:623-628`, `984-988`).
- Each newly opened video gets `announce()` (`core/session.rs:516-522`), which sends `video-start` and then `displays`. **`displays` is sent only when the host has 2 or more displays** (`:558-567`).
- The host answers a `key-frame` by forcing a key frame (unless one is already in flight) and **sending `video-start` again**, plus `displays` and `codec-offer` again (`core/session.rs:4967-5002`).
- **Sound** is captured only after `{"type":"audio","on":true}`, and only if `hear-sound` was granted (`core/session.rs:4728-4743`).

### 1.4 Order the Go viewer uses after the session is `connected`

The Go viewer does this through the engine's local socket, which wraps the same media read and write.

1. `syncViewers` sees `state=="connected"` and starts `pump()` (`internal/gui/viewer.go:654-730`, start at `:710-728`). It sets `control` when `control-input` is granted and `clip.may` from `clipboard`/`files`, and shows "no picture" without `view-screen`.
2. `pump()` (`internal/gui/viewer.go:797-962`) writes these packets in order:
   1. `{"type":"key-frame"}` (`:821-822`).
   2. `choicePackets()` (`internal/gui/viewerinput.go:436-454`):
      - `quality` (always),
      - `codec` (only if the choice is not `auto`),
      - `{"on":false,"type":"hardware"}` (only if the viewer chose software),
      - `{"on":true,"type":"lock-after"}` (only if chosen and the host has `lock-after`),
      - `{"type":"audio","on":!mute}` (always),
      - `clipboard-use` (`internal/gui/viewerclip.go:174`).
3. It then reads packets in a loop:
   - `VIDEO_START` and `FRAME` go through `videoGate` (`viewer.go:1004-1059`). An identical `VIDEO_START` is ignored.
   - `AUDIO` goes to the sound goroutine.
   - `DISPLAYS` is handled with `keepScreen`, which may send `{"type":"display","index":n}` (`:887-903`).
   - `CODECS`, `ACTIONS`, `CURSOR`, `CLIPBOARD`, `STATS` and `INPUT` are each parsed in place (`:904-958`).
4. A watchdog runs every second (`viewer.go:1160-1212`). It asks for a key frame when needed. When nothing has shown for 2 s or more it sends `{"type":"no-picture","for_ms":ms,"why":"waiting"|"decode-error"|"stale"}`. The engine forwards that only to hosts that announced the `recovery` feature (`core/session.rs:4600-4604`).
5. In the decode loop (`viewer.go:1219-1292`), a new `VIDEO_START` that is **not equal** to the current one closes the decoder and opens a new one. An equal one is kept: "a new group of pictures, which the decoder takes as it is" (`:1238-1246`). Frames are dropped until a key frame arrives on a fresh decoder (`:1264`).

---

## 2. Packet byte layouts (engine to GUI, `kyokai_media_read`)

The kinds are defined in `core/media.rs:27-68`. Byte 0 is the kind. Every JSON body starts at byte 1 and is UTF-8 with no terminator. **All binary integers are big-endian.**

| Kind | Name | Body (from byte 1) | Producer |
|---|---|---|---|
| 1 | VIDEO_START | JSON `media::VideoStart` | `core/session.rs:4891-4896` |
| 2 | FRAME | `flags:u8`, `pts_us:u64 BE`, `data…` | `core/session.rs:4633-4639` |
| 3 | CONTROL | GUI to engine only | — |
| 4 | STATS | JSON `{delay_ms, fps, bitrate, encode_ms, frames, video}` | `core/session.rs:4769-4783` |
| 5 | AI_TASK | JSON task object, raw and not wrapped | `core/session.rs:4870-4875` |
| 6 | AI_ERROR | JSON `{error}` | `:4884-4889` |
| 7 | CURSOR | JSON `{x, y, visible}` | `:4863-4868` |
| 8 | DISPLAYS | JSON `{list:[{x,y,width,height,primary}], current}` | `:4957-4962` |
| 9 | ACTIONS | JSON `{ctrl_alt_del, blocked, privacy}` | `:5158-5163` |
| 10 | AI_DRAFT | JSON `{text}` | `:4787-4792` |
| 11 | CODECS | JSON `{codecs:[names]}` | `:4950-4955` |
| 12 | AUDIO | **one raw Opus packet**, with no other header | `:4650-4657` |
| 13 | CLIPBOARD | JSON `{from, at, text}`, `{from, at, png}` or `{from, at, files}` | `core/session.rs:1152-1169` |
| 14 | TUNNEL | tunnel bytes, both directions | — |
| 15 | INPUT | JSON `{paused: bool}` | `:4375-4385`, `:5172-5178` |
| 16 | AI_EXPORT | JSON `{id, markdown}` | `:4877-4882` |

**Queue coalescing** (`core/media.rs:258-344`):

- Only the newest STATS, AI_TASK, CURSOR, DISPLAYS, ACTIONS, CODECS or INPUT packet is kept while it waits.
- A VIDEO_START identical to the last one waiting is dropped.
- AUDIO keeps at most 20 waiting packets (200 ms) and CLIPBOARD at most 8. The oldest is dropped first.
- FRAME keeps at most `MAX_IN_FLIGHT = 12` waiting (`core/video.rs:502`). When a slow reader overflows that, the frames go and every frame until the next key frame is skipped, except that the newest key frame is kept.

### 2.1 VIDEO_START (`core/media.rs:70-96`)

```json
{"codec":"h264","width":1920,"height":1080,"i444":true,"encoder":"media-foundation","hardware":true,"placeholder":"no-display","size":"auto"}
```

- `codec` is one of `raw-rgba`, `h264`, `hevc`, `vp9` (Media Foundation), `vp9-sw` (libvpx), `av1` or `vp8`, or `mjpeg` for NanoKVM (`core/kvm.rs:35`). The host's order is in `core/video.rs:576-581`.
- `width` and `height` are the **encoded** size. It is even on both sides and already scaled by `fit_short` (`core/video.rs:438-453`). It is not the host display's size.
- `i444` appears only when true. It is possible only for `vp9-sw` and `av1` (`choose`, `core/video.rs:600-611`). **H.264 and HEVC are always 4:2:0.**
- `encoder` and `hardware` describe the host's encoder. `placeholder` is one of `asleep`, `no-display`, `agent`, `no-encoder`, `retrying`, `no-codec`, `cannot-capture` or `nanokvm` (`core/video.rs:799-808`); when it is present, the stream is the test pattern. `size` is the size choice in force (`auto`, `native`, `2160`, `1440`, `1080` or `720`); older hosts leave it out.
- **There is no extradata, SPS/PPS or `csd` field.** The stream is **Annex B** with in-band parameter sets on every key frame:
  - The wire format is documented in `core/annexb.rs:1-6`.
  - VideoToolbox writes VPS/SPS/PPS before every key frame (`core/vt.rs:523-547`).
  - Media Foundation's H.264 and HEVC encoders put the parameter sets on every key frame (test at `core/mf.rs:1280-1305`).
  - VA-API emits "Annex B out with the parameter sets on each key frame" (`core/va.rs:223`, test at `:443` expecting SPS, PPS, IDR).
- The placeholder test pattern is `codec:"raw-rgba"` at 320×180 and 15 fps. Every frame is a key frame of `w*h*4` RGBA bytes (`core/media.rs:388-443`, `core/video.rs:1120-1141`). **`kyokai_decoder_open` handles `raw-rgba` on Android**, since that decoder is cross-platform (`core/decode.rs:65-69`). It does not handle `mjpeg` there (`:70-71` is limited to Windows, macOS and Linux).

### 2.2 FRAME

```
[0]=2 | [1]=flags (bit0 = KEY_FRAME, core/media.rs:22) | [2..10]=pts_us u64 BE | [10..]=frame bytes
```

- `pts_us` counts microseconds since the host's capture or encoder thread started (`core/video.rs:1130`, `1780`). It restarts with each new stream.
- **There is no display index in a frame.** The display is chosen by the `display` control message and reported in `DISPLAYS.current`.
- On the wire between host and controller, frames travel as chunks. Each chunk header is `0x01, frame:u32, index:u16, count:u16, flags:u8, pts:u64`, all BE (`core/media.rs:18-20`, `99-122`). The engine reassembles them, so the GUI never sees chunks.

### 2.3 CURSOR

`{"x":f32,"y":f32,"visible":bool}`

- `x` and `y` are **fractions (0–1) of the picture** (`core/session.rs:433-439`).
- There is no image and no hotspot; the host sends position only. The Go viewer draws a ring (`pointerRing`, `internal/gui/viewer.go:2017`).
- The captured picture leaves the pointer out (`internal/gui/viewer.go:292`).
- The host polls every 16 ms and sends only changes (`core/session.rs:569-571`).

### 2.4 DISPLAYS

`{"list":[{"x":i32,"y":i32,"width":u32,"height":u32,"primary":bool}],"current":usize}`

- Coordinates are pixels on the host's virtual desktop (`core/video.rs:738-746`).
- The list is ordered primary first, then by x, then by y (`core/video.rs:770-774`).
- `current` indexes into `list`, and the `display` message uses the same index.
- The packet is sent only when the host has 2 or more displays.

### 2.5 STATS

| Field | Meaning |
|---|---|
| `delay_ms` | round trip measured by the host's probes |
| `fps` | frame rate QoS chose |
| `bitrate` | **bits per second** |
| `encode_ms` | average time from capture to encoded frame |
| `frames` | frames sent in the last second |
| `video` | `"live"`, `"dark"`, `"recovering"` or `"placeholder"`, and empty from hosts at 0.5.2 or older |

Definition at `core/session.rs:301-319`; sent once a second (`:4478-4479`).

### 2.6 AUDIO

The body is one **Opus** packet: **48 kHz, stereo, 10 ms frames** (480 samples per channel). See `core/opus.rs:10-15` and `core/android/opus.rs:5-7`. The wire form is `0x04 + opus` (`core/session.rs:3546-3552`), and the GUI packet is `12 + opus`.

There is no timestamp and no length prefix. **On Android the core has no Opus decoder:** `kyokai_audio_open` returns 0 (`core/android/opus.rs:26-28`, via `core/decode.rs:163` and `core/lib.rs:541`).

### 2.7 CLIPBOARD (history only)

- `{"from":"controller"|"host","at":unix_ms,"text":...}`, or `"png":base64` (8-bit RGBA PNG), or `"files":[{...}]` (`core/session.rs:1141-1169`).
- A packet with `from:"host"` is pushed only when clipboard sharing is permitted and `clipboard-use` is `share:true, front:true` (`core/session.rs:4804-4837`).
- Text is limited to `MAX_TEXT = 1 MiB` (`core/clipboard.rs:18`).

### 2.8 ACTIONS and INPUT

- ACTIONS is `{"ctrl_alt_del":bool,"blocked":bool,"privacy":bool}`. Only sessions with `control-input` get it, and only Windows hosts implement the actions (`core/session.rs:440-453`, `5156-5157` makes `Action` a no-op on other hosts).
- INPUT is `{"paused":bool}`. While it is true, `kyokai_media_write` returns -3 for presses and moves; releases still go through.

---

## 3. Control messages (GUI to engine: `0x03` + JSON)

Only the following message types reach the host (`core/session.rs:4586-4613`). Anything else is silently dropped:

`key-frame`, `display`, `codecs`, `input`, `action`, `quality`, `codec`, `audio`, `lock-after`, `ai-start`, `ai-command`, `ai-decide`, `ai-draft`, `no-picture`

The engine handles `hardware` and `clipboard-use` locally (`:4537-4585`). Serde enum: `core/session.rs:248-458`, tagged `type` in kebab-case.

| type | Fields | Meaning, units, source |
|---|---|---|
| `key-frame` | — | Ask for a key frame. The host also re-sends `video-start`, `displays` and `codec-offer` (`core/session.rs:257-258`, `4967-5002`). |
| `display` | `index: usize` | Show the display at that index of the DISPLAYS `list` (`:403-406`, `4900-4906`). |
| `quality` | `preset`, `fps: u32`, `i444: bool`, `size?: string`, `custom?: u32` | `preset` is `"speed"`, `"balanced"`, `"best"` or `"custom"` (`core/session.rs:665-677`). `fps` applies when it is in 1..=60 (`MAX_FPS`, `core/video.rs:352`; `core/session.rs:4703-4706`). `size` is `auto`, `native`, `2160`, `1440`, `1080` or `720` (`core/video.rs:386-398`), and the host reopens the video when it changes. `custom` is a percentage in 10..=2000 (`core/session.rs:660`), where 50 means a bitrate ratio of 1. Go builds this message at `internal/gui/viewerinput.go:241-256`. |
| `codec` | `codec: "auto"` or a name from the offer | Prefers that codec; the video restarts if the first choice changes (`:419-422`, `4938-4948`). |
| `hardware` | `on: bool` | Handled by the engine: it re-reads `decodable()` and re-sends `codecs` (`:4537-4549`). **On Android this is the way to re-advertise after calling `android.decoders` again mid-session.** |
| `codecs` | `decode: [names]`, `i444: [names]` | Allowed directly too. Prefer `android.decoders`, because a resumed session re-sends `decodable()` (`:3791-3794`). |
| `audio` | `on: bool` | The host captures sound only while this is on and `hear-sound` is granted. |
| `lock-after` | `on: bool` | Lock the host when the session ends. Needs host feature `lock-after`. |
| `action` | `action: "lock"`, `"ctrl-alt-del"`, `"block"`, `"unblock"`, `"privacy-on"`, `"privacy-off"` or `"wake"` | `core/session.rs:460-477`. Effective on Windows hosts only (`:5156-5157`). On a host without the `wake` feature, `wake` becomes a Shift press and release (`:4605-4611`). |
| `no-picture` | `for_ms: u32`, `why: "waiting"`, `"decode-error"` or `"stale"` | Forwarded only to hosts announcing `recovery` (`:259-267`, `4600-4604`). |
| `clipboard-use` | `share: bool`, `front: bool` | Local to the engine. `front:false` holds what was copied until the app returns to the front (`:4551-4585`). |
| `input` | `event: {...}` (below) | Goes through the `InputGate`, which never waits (`core/lib.rs:376-382`). |
| `ai-*` | see `core/session.rs:320-369` | Not needed for a basic viewer. |

**Clipboard from the device to the host is not a control message.** Call `kyokai_call {"method":"android.clipboard","params":{"text":...}}` (`core/lib.rs:1552-1557`). That bumps the serial of `android::Board` (`core/android/mod.rs:40-46`). The share thread polls it every 500 ms (`core/clipboard.rs:24`, `317-342`) and sends the text to the host. **Clipboard from the host** reaches the app only as CLIPBOARD packets with `from:"host"`. `Board::set` stores the text but never writes the Android clipboard (`core/android/mod.rs:60-86`), so the app copies it itself.

### 3.1 Input events (`core/input.rs:12-48`, tagged `kind`, kebab-case)

**Pointer**

```json
{"kind":"pointer","action":"move"|"down"|"up","button":0|1|2,"x":f32,"y":f32}
```

- `x` and `y` are **normalized fractions 0–1 of the shared picture**, not pixels (`core/input.rs:12-13`).
- Button 0 is primary, 1 secondary and 2 middle (`:17-24`, `148-152`).
- **There is no relative mouse, touch or multi-touch event.** Emulate them with pointer events.
- Go clamps positions to 0–1 within the letterboxed picture box. A press outside the picture is dropped, but a release always goes (`internal/gui/viewerinput.go:125-153`).

**Scroll**

```json
{"kind":"scroll","dx":f32,"dy":f32}
```

- The unit is **wheel notches (lines)**. Positive `dy` moves the content down (`core/input.rs:25-26`).
- Go divides platform DIPs per notch (99 on Windows, 40 on macOS, 50 elsewhere) and clamps to ±100 (`internal/gui/viewerinput.go:94-114`, `154-159`).

**Key (Legacy mode)**

```json
{"kind":"key","key":name,"down":bool,"mods":{"shift","ctrl","alt","meta"}}
```

- Valid names are those `vk()` accepts (`core/input.rs:338-385`):
  - `a`–`z`, `0`–`9`, `f1`–`f24`
  - `enter escape backspace tab space delete insert home end page-up page-down left up right down`
  - `minus equal comma period slash semicolon quote bracket-left bracket-right backslash backquote`
  - `context-menu caps-lock print-screen shift ctrl alt meta`
- The Go Legacy path sends printable keys **as `text` when no Ctrl, Alt or Meta is held**, and as `key` otherwise (`internal/gui/viewerinput.go:61-81`, `160-173`).

**Text**

```json
{"kind":"text","text":"…"}
```

At most 4096 bytes per event (`core/input.rs:167-168`). Go splits clipboard typing into pieces (`internal/gui/viewerinput.go:1190-1219`).

**Scan (Map and Translate modes)**

```json
{"kind":"scan","code":u32,"down":bool,"caps":bool,"num":bool}
```

- `code` is a **Windows PS/2 set-1 scan code**: `0x01..=0xFF`, `0xE0xx` for extended keys, or `0xE11D` for Pause (`core/input.rs:36-54`).
- `0xE036` is read as Right Shift, `0x36` (`:56-74`).
- `caps` and `num` carry the controller's lock state. The host syncs CapsLock before a letter and NumLock before a numpad key (`:91-101`).
- Go builds the event with `scanEvent` (`internal/gui/viewerinput.go:1162-1165`).

**Translate mode** uses the same `scan` events for non-typing keys. Typing keys reach the window and go as `text` (`internal/gui/viewerinput.go:116-125`, `992-1037`; `core/keyboard.rs:69-78`).

**Ctrl/Cmd swap** is done on the controller side, and Go does it in `queue` (`internal/gui/viewerinput.go:584-600`). `swapCtrlMeta` exchanges `mods.ctrl` and `mods.meta`, and for scan codes exchanges `0x1D ↔ 0xE05B` (left) and `0xE01D ↔ 0xE05C` (right) (`:387-408`).

**`sync` events** are generated by the **engine**, not the GUI, for hosts with `input-sync` (`core/input.rs:328-336`; `core/session.rs:4386-4392`).

On a full queue Go never drops a release (`internal/gui/viewerinput.go:567-619`). Pointer moves are coalesced to at most one per 8 ms (`:563-565`, `634-687`).

---

## 4. Codec negotiation

1. The controller advertises `codecs {decode, i444}`. On Android `decode` is whatever the app passed to `android.decoders` and `i444` is always `[]` (`core/video.rs:733-736`). The default before any call is **empty** (`core/android/mod.rs:18`).
2. The host computes `chosen = choose(decode, i444, full_colour, hevc_first)`:
   - It walks `ORDER` and keeps the codecs present in `decode` (`core/video.rs:592-630`).
   - `hevc_first` is set when the host has a free hardware HEVC encoder (`:669-688`).
   - The viewer's `codec` choice is then moved to the front by `prefer` (`:661-667`).
   - It sends `codec-offer {codecs}` = `offer(decode, encodable())` (`:651-656`), which becomes the `CODECS` packet.
3. The host opens the first candidate whose encoder starts. Under `size:"auto"` the ceiling is up to 2160 for `h264`, `hevc` and Media Foundation `vp9` (the "viewer decodes in hardware" assumption) and 1080 otherwise (`core/video.rs:409-422`, `1468-1471`).

**To get only H.264 or HEVC 4:2:0:**

- Call `android.decoders {"decode":["h264","hevc"]}` **before** `session.connect`.
- Optionally send `{"type":"codec","codec":"hevc"}` or `"h264"` to pin one.
- Full colour cannot be chosen, both because i444 is empty and because H.264/HEVC full colour does not exist in `choose`.
- If the decode list is empty: a Windows host still falls back to H.264 after 1 s, but **macOS and Linux hosts send the `no-codec` placeholder**.
- Under `auto` a host may send 4K. If the device's `VideoCapabilities` cannot take that, send `quality.size:"1440"` or `"1080"`.

---

## 5. Review of the Kotlin drafts and the core's Android pieces

### 5.1 Matches the protocol

- `MainActivity.kt:284-298` uses the frame layout texture id `i64 BE`, then `flags:u8`, then `pts:u64 BE`, then data. That equals `[texture id] + FRAME packet[1..]`, so Dart only replaces byte 0 with the 8-byte id.
- `Video.kt:15-21` assumes Annex B with in-band parameter sets on key frames, which is correct (section 2.1).
- `Sound.kt` targets Opus at 48 kHz stereo in 10 ms packets, which is correct. The `OpusHead` it builds (`Sound.kt:129-139`) is 19 bytes and follows RFC 7845.
- `MasterKey.kt` produces the base64 of 32 bytes that `kyokai_start`'s `master_key` expects (`core/lib.rs:202-206`, `core/android/mod.rs:21-33`).

### 5.2 Bugs and risks

1. **No `KEY_MAX_INPUT_SIZE`** (`Video.kt:120-128`). The default input buffer is sized for `width×height` and is often smaller than an IDR with its parameter sets at high bitrate. `submit()` then queues an empty buffer and calls `fail()` → `restart()` → `wantKey` → the next key frame is too large again, which is a **permanent loop**. Set `KEY_MAX_INPUT_SIZE`, for example to `max(w*h*3/2, 4 MiB)`.
2. **Re-entrant stop/release from inside the codec's own callback.** `submit()` runs inside `onInputBufferAvailable` and calls `fail()` → `restart()` → `stopCodec()` → `stop()`/`release()` synchronously on the callback thread (`Video.kt:87-113`, `132-135`, `160-170`). Some Android versions deadlock or throw on this. Post the restart instead (`handler.post { restart() }`), as `onError` already does.
3. **A configure failure becomes a key-frame storm.** If `createByCodecName` or `configure` throws, `failed = true` and `codec == null` (`Video.kt:153-155`). Each `feed` then reports failure once, Dart asks for a key frame, and the host re-sends `video-start` (section 1.3). The app should report "unsupported" instead, as Go does (`internal/gui/viewer.go:1251-1256`).
4. **Restart twice at open, and a key frame asked for on every restart.** `init` posts `restart()` (`Video.kt:58`) and `onSurfaceAvailable` posts it again (`:48-50`), so there are two `wantKey` calls. A restart while frames flow also discards the stream.
5. **Reopening on an identical VIDEO_START would loop.** Every `key-frame` request makes the host send the same `video-start` again (`core/session.rs:4976`). If Dart closes and reopens `Video` on every VIDEO_START, then restart → wantKey → video-start → reopen repeats forever. **Compare the VIDEO_START bytes** and reopen only on a change, as `videoGate.start` (`viewer.go:1037-1059`) and `decodeVideo` (`:1238-1246`) do. The core queue's de-dup covers only a duplicate still waiting (`core/media.rs:266-276`).
6. **Parameter sets are not marked `BUFFER_FLAG_CODEC_CONFIG`.** SPS/PPS/IDR go in one buffer flagged `BUFFER_FLAG_KEY_FRAME`, which has no meaning for decoder input (`Video.kt:101`). Most Qualcomm and Exynos decoders accept in-band parameter sets, but some reject an IDR before configuration. The robust approach is to split leading NAL types 7/8 (H.264) or 32–34 (HEVC), using the same rules as `core/annexb.rs:16-46`, and queue them first with `BUFFER_FLAG_CODEC_CONFIG`, or set them as `csd-0`/`csd-1` before `configure`.
7. **No size or capability check.** `decoderFor` picks the first hardware decoder for the MIME type without checking `VideoCapabilities.isSizeSupported(w,h)` or profile/level, and does not skip `.secure` decoders (`Video.kt:200-206`). A 4K `auto` stream can fail on mid-range devices. Fall back to the next decoder, or cap with `quality.size`.
8. **`decodable()` advertises codecs this client does not handle** (`Video.kt:208-210`):
   - It always appends `"mjpeg"`, but `Video.open` has no MIME type for it and `kyokai_decoder_open` does not support `mjpeg` on Android (`core/decode.rs:70-71`).
   - It advertises `vp9`, `vp9-sw`, `av1` and `vp8` too, which contradicts the H.264/HEVC-only goal.
9. **`raw-rgba` placeholders are not handled.** `Video.open` returns null for `raw-rgba` (`Video.kt:219`), yet hosts send it for every placeholder (section 2.1). Use `kyokai_decoder_open`/`kyokai_decoder_decode`, which work for `raw-rgba` on Android, or copy the RGBA into an image directly.
10. **Frames pile up without a surface.** While the app is in the background (`onSurfaceCleanup`, `Video.kt:52-56`), `codec == null`, so frames accumulate. Every 9 frames the queue is cleared and `wantKey` fires (`:75-79`), which means repeated key-frame requests. Pause reading or ask for nothing while there is no surface.
11. **Two copies per frame.** Each frame is copied into a `ByteArray` (`Video.kt:63-64`) and again into the codec buffer. This is acceptable but avoidable.
12. **`Sound.kt` misses several cases:**
    - Its `onError` is a no-op (`:67`), so a codec error silences sound for good.
    - Every input uses `presentationTimeUs = 0` (`:91`). Use an increasing time in 10 000 µs steps.
    - `play()` ignores `info.offset` (`:62-63`, `:105`).
    - `play()` ignores the return value of `AudioTrack.write(..., WRITE_NON_BLOCKING)`, so `written` drifts whenever a write is short (`:106-107`).
    - It ignores `onOutputFormatChanged`, so a change of channel count or PCM encoding is not followed.
    - Pre-skip is 0. That is harmless but differs from the encoder's lookahead.
13. **`Sound` alone does not start the host's sound.** The Dart side must also write `{"type":"audio","on":true}`, request `hear-sound`, and strip byte 0 (12) before feeding the `kyokai/sound` channel.
14. **`MasterKey.kt` can lose its key or fail silently:**
    - The result of `tmp.renameTo(file)` is unchecked (`MasterKey.kt:203-205`). If the rename fails, the fresh key is returned but never persisted, and the next run makes a new key, which leaves the store `Unreadable`.
    - If the Keystore alias is lost (backup restore, or the lock screen was reset on some OEMs), decrypting throws `AEADBadTag` and every run silently goes to memory-only.
    - Surface this to the user and offer the core's `store.start_over`. Note issue 15 first.
15. **Core bug: `start_over` and `reopen_store` lose the Android key.** `android::master_key()` *takes* the key once (`core/android/mod.rs:35-38`). It is set again only in `build()` (`core/lib.rs:835-838`). `rebuild_on_store` calls `store::open` directly (`core/lib.rs:956`) without seeding the key again, so on Android `store.start_over` (`:917-937`) rebuilds as **MemoryOnly** (`core/store.rs:617-631`). Fix by calling `android::set_master_key` in `rebuild_on_store` as well, or by not using `take()`.
16. **The core grabs no keyboard on Android.** `kyokai_keyboard_read` and `kyokai_keyboard_state` return -2 there (`core/lib.rs:655-657`, `689-691`), so the app must build its own `scan` events. For hardware keyboards, `KeyEvent.getScanCode()` returns a Linux evdev code; map it to set 1 with the inverse of `scan_evdev` (`core/linux.rs:748-790`; inverse `evdev_scan` at `:792-800`). The soft keyboard and IME have no scan codes, so send `text`, plus `key` for Enter, Backspace, arrows and similar.
17. **Clipboard needs the app's help.** `clipboard-use.front` should follow whether the app is in front (Android forbids background clipboard reads). Host-to-device text arrives only as CLIPBOARD packets, which the app copies itself.
18. Smaller issues:
    - `MainActivity` runs `Video.open` (a `MediaCodecList` scan, repeated per codec inside `hardwareOf`) on the platform thread.
    - `onDestroy` closes the decoders, so an Activity recreated without `configChanges` would orphan Dart's texture ids.
    - Nothing in `MainActivity` forwards `decoders` to the core. Dart must call `android.decoders` with it.

---

## 6. The host's OS for the keyboard

**Where to read it:**

- `status.sessions[].peer.os` for the live session (`core/session.rs:1606`, field `peer: About` at `:909-910`; Go `SessionInfo.Peer.OS`, `internal/localapi/protocol.go:852-853`).
- `status.recent[].about.os` for the last session with a host (`core/lib.rs:1985-1988`).
- `About.os` is set from a compile-time constant: `"windows"` or `"macos"`, and **`""` for Linux and Android hosts** (`core/about.rs:21-34`, `142-156`). An empty value therefore means "Linux or unknown".

**What the OS is used for in Go:**

- Only the Ctrl/Cmd swap default: `swapDefault(runtime.GOOS, v.phase.Peer.OS)` swaps only between a Mac and Windows (`internal/gui/viewerinput.go:363-385`).
- For an Android controller, the swap would be a product choice. For example, swap when `peer.os == "macos"` so that Ctrl+C on the device sends Cmd+C.

**Map mode needs no host OS for correctness.** The controller always sends Windows set-1 scan codes, and each host translates them:

- macOS: `scan_keycode`, which returns None for NumLock and ScrollLock (`core/mac.rs:902-905`).
- Linux: `scan_evdev` (`core/linux.rs:748`).
- Windows: `SendInput` by scan code (`core/input.rs:80-89`).

The **host's** layout decides the characters. Use `peer.os` only for key-cap labels (Win/⌘, Alt/⌥) and for the swap default.

Host features (for example `lock-after`, `custom-quality`, `resolution`, `recovery`, `wake`, `input-sync`) are listed in `status.recent[].features` (`core/lib.rs:1988`; Go `hostHas`, `internal/gui/ailink.go:364-376`).
