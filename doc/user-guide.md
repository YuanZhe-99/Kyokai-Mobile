# Using Kyokai for Android

## First start

Kyokai starts its core and gives this phone a 9-digit Device ID (Settings →
This device). The phone only controls: nobody can connect to it.

## Reaching your computers

- **Networks** (Settings → Networks): add the EasyTier network your
  computers use: its servers (one per field; Enter adds the next), name and
  secret. Up to eight, all joined at once.
- **By address**: type a computer's address (LAN IP, host name) or Device ID
  in the search field on Devices and tap Connect.

Devices lists the computers you have connected to, online first, with live
CPU, memory and disk where the host allows it.

## A computer's page

Tap a device for its page:

- **Open desktop**: its screen. The first time, type its Kyokai password
  (Remember keeps it).
- **AI task**: its AI, when you may run tasks there. The clock icon shows the
  tasks it showed while you were connected.
- **SSH, Remote Desktop, VNC**: the computer's own services through Kyokai.
  From SSH, **Files** browses it over SFTP: open folders, upload, download,
  rename, delete.
- **NanoKVM**: when the computer has a NanoKVM USB, the computer wired to it.
- **Wake the screen**: turns its display back on (also the sun icon on the
  device list, and the button the screen shows while asleep).
- **Routes**: how Kyokai reaches it (Auto, the network, or an address).
- **Sign-in**: what is saved for it, each forgotten on its own.

## On a desktop

- **Touch**: tap to click, drag to move or select, two fingers to scroll,
  pinch to zoom. Settings → Input chooses touch or touchpad and the cursor's
  size.
- **Keyboard**: the keyboard button opens the full keyboard (Ctrl, Alt,
  Win/Cmd, function keys, arrows) with a touchpad; a hardware keyboard and
  mouse work as they are.
- **The menu** (⋮): quality, sound, sharing the clipboard, typing text,
  clipboard history, switching to another open desktop, session actions,
  disconnect.
- In landscape the toolbar folds into an arrow you can drag anywhere; tap
  it to show the toolbar.
- On a foldable, half-fold the phone for the laptop layout.

## Clipboard

While a desktop shares the clipboard, text and images you copy on the phone
go to the computer, and what you copy there comes to the phone. Files copied
on a computer are listed but not received on Android. Sessions → the
clipboard icon, or the desktop's menu, shows the history; tap an entry to
copy it again.

## Sessions

Sessions lists what is open: desktops, AI links, NanoKVM, SSH, Remote
Desktop and VNC. Tap one to go back to it; × ends it. Sessions stay open in
the background (Android shows a notification).

## Sign-in keys

Settings → Sign-in keys makes or imports keys for signing in to SSH and to
Kyokai hosts that admit them: Ed25519, RSA (2048 bits or more) and ECDSA
P-256 or P-384, from OpenSSH or PEM files, with their passphrase if they have
one. Private keys stay in Kyokai's encrypted store.

## Problems

Settings → Diagnostics shows the core, video and network state and shares
the log. "Show video details" overlays codec, decoder, frame rate and the
time to the first frame.
