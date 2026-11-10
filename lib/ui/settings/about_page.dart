// The app's license, as MyAnime shows its own: the notice, what the APK
// ships and under which terms, and where the source is. Flutter's own
// license page (Open source licenses) lists the Dart packages; the native
// parts are registered with it in [registerNativeLicenses].

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shell/app.dart';

const sourceUrl = 'https://github.com/YuanZhe-99/Kyokai-Mobile';
const kyokaiUrl = 'https://github.com/YuanZhe-99/Kyokai';

class AppLicensePage extends StatelessWidget {
  const AppLicensePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.aboutLicense),
        actions: [
          IconButton(
            tooltip: l.aboutSource,
            icon: const Icon(Icons.code),
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: sourceUrl));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.copied}: $sourceUrl')));
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(licenseText, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}

const licenseText = '''Kyokai for Android - Copyright (C) 2026 yuanzhe

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, version 3.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

Source: $sourceUrl

It ships, as native libraries:

Kyokai Core (libkyokai_core.so): networks, sessions, keys and the
secrets store, shared with Kyokai on the desktop.
GNU AGPL version 3 only. Source: $kyokaiUrl
Its Rust crates and their licenses: RUST_LICENSES.txt in Kyokai's builds.

Kyokai's service clients (libkyokai_clients.so, cmd/kyokai-clients in
Kyokai): SSH, Remote Desktop and VNC. GNU AGPL version 3 only.
- open-screen-sharing (the Remote Desktop and VNC clients, modified),
  Copyright (C) 2026 nekohasekai, GPL-3.0-or-later.
  https://github.com/nekohasekai/open-screen-sharing
  No derivative work may use its name or imply association with it
  without prior consent.
- golang.org/x/crypto (SSH), BSD-3-Clause. https://go.googlesource.com/crypto

MyApps-UI (myapps_ui, myapps_adaptive), Copyright (C) 2026 yuanzhe and
contributors. GNU GPL version 3. https://github.com/YuanZhe-99/MyApps-UI

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

---

GNU AFFERO GENERAL PUBLIC LICENSE
Version 3, 19 November 2007

The full license text is available at:
https://www.gnu.org/licenses/agpl-3.0.html

Key points:
- You may use, study, share and change this program.
- If you share it, changed or not, you must share its source under the
  same license.
- If you let others use a changed version over a network, you must offer
  them its source too.
''';

/// Adds the native libraries to Flutter's license page, beside the Dart
/// packages it lists by itself.
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Kyokai Core', 'Kyokai service clients'], '''Copyright (C) 2026 yuanzhe.
GNU Affero General Public License, version 3 only.
$kyokaiUrl''');
    yield const LicenseEntryWithLineBreaks(['open-screen-sharing'], '''Copyright (C) 2026 nekohasekai.
GNU General Public License, version 3 or later. In addition, no derivative work may use the name or imply association with this application without prior consent.
https://github.com/nekohasekai/open-screen-sharing''');
    yield const LicenseEntryWithLineBreaks(['golang.org/x/crypto'], '''Copyright 2009 The Go Authors.
BSD-3-Clause. https://go.googlesource.com/crypto''');
    yield const LicenseEntryWithLineBreaks(['MyApps-UI'], '''Copyright (C) 2026 yuanzhe and contributors.
GNU General Public License, version 3. https://github.com/YuanZhe-99/MyApps-UI''');
  });
}
