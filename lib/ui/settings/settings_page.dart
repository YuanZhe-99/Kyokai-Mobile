// Settings: this device, networks, sign-in keys, appearance, input, the
// diagnostics.

import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:myapps_adaptive/myapps_adaptive.dart';
import 'package:myapps_ui/myapps_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../build_info.dart';
import '../../data/app_state.dart';
import '../../data/key_import.dart';
import '../../data/model.dart';
import '../shell/app.dart';
import 'about_page.dart';
import 'cursor_size.dart';
import 'diagnostics_page.dart';
import 'networks_page.dart';

/// The settings rows that open a page of their own: pushed on a phone, in
/// the right-hand pane on a wide window (an unfolded fold, a tablet).
enum SettingsDetail { networks, keys, diagnostics, license }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SettingsDetail? _detail;
  bool _twoPane = false;

  Widget _page(SettingsDetail d) => switch (d) {
    SettingsDetail.networks => const NetworksPage(),
    SettingsDetail.keys => const KeysPage(),
    SettingsDetail.diagnostics => const DiagnosticsPage(),
    SettingsDetail.license => const AppLicensePage(),
  };

  /// Every row that leads to a page goes through here, so the two layouts
  /// cannot drift apart.
  void _open(SettingsDetail d) {
    if (_twoPane) {
      setState(() => _detail = d);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _page(d)));
  }

  /// A row that opens [d]: marked while its page shows in the pane.
  Widget _row(SettingsDetail d, {required IconData icon, required String title, String? subtitle}) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    selected: _twoPane && _detail == d,
    onTap: () => _open(d),
  );

  Widget _pane() {
    final d = _detail;
    if (d == null) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_outlined, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(context.l.settingsSelectItem, style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }
    // A route of its own: the page's app bar grows no back arrow, and
    // its own pushes stay inside the pane.
    return Navigator(
      key: ValueKey(d),
      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => _page(d)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final split = canSplitLayout(screen.width, screen.height);
    _twoPane = split;
    return Scaffold(
      body: MyAppsPaneBody(
        primary: _list(context),
        secondary: _pane(),
        allowSplit: split,
        primaryWidthFor: (w) => (w * 0.44).clamp(300.0, 440.0).clamp(240.0, max(240.0, w - 280)),
        topInset: 0,
        onSplitChanged: (v) => _twoPane = v,
      ),
    );
  }

  Widget _list(BuildContext context) {
    final l = context.l;
    final state = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([state.engine, state.prefs]),
          builder: (context, _) {
            final status = state.engine.status;
            final prefs = state.prefs;
            final net = status.network;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
              children: [
                Text(l.navSettings, style: Theme.of(context).textTheme.headlineSmall),
                MyAppsSettingsSection(
                  title: l.sectionThisDevice,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(l.deviceId),
                      subtitle: Text(formatId(status.deviceId), style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
                      trailing: IconButton(
                        tooltip: l.copy,
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: status.deviceId));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
                        },
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l.deviceName),
                      subtitle: Text(status.name.isEmpty ? '–' : status.name),
                      onTap: () async {
                        final name = await _ask(context, l.deviceName, status.name);
                        if (name != null) await state.engine.act<Object?>('device.set_name', {'name': name});
                      },
                    ),
                    if (status.persistence != 'os-store')
                      ListTile(
                        leading: Icon(Icons.warning_amber, color: cs.error),
                        title: Text(l.memoryOnly),
                        subtitle: Text(l.memoryOnlyHint),
                      ),
                  ],
                ),
                MyAppsSettingsSection(
                  title: l.sectionNetworks,
                  children: [
                    _row(
                      SettingsDetail.networks,
                      icon: Icons.hub_outlined,
                      title: l.networks,
                      subtitle: '${net.networks.length} · ${net.state}${net.address.isEmpty ? '' : ' · ${net.address}'}',
                    ),
                  ],
                ),
                MyAppsSettingsSection(
                  title: l.sectionKeys,
                  children: [
                    _row(SettingsDetail.keys, icon: Icons.key_outlined, title: l.signInKeys, subtitle: l.signInKeysHint),
                  ],
                ),
                MyAppsSettingsSection(
                  title: l.sectionAppearance,
                  children: [
                    MyAppsSettingsSegmentRow<ThemeMode>(
                      leading: const Icon(Icons.brightness_6_outlined),
                      title: l.theme,
                      selected: {prefs.themeMode},
                      onSelectionChanged: (v) => prefs.themeMode = v.first,
                      segments: [
                        ButtonSegment(value: ThemeMode.system, label: Text(l.themeSystem)),
                        ButtonSegment(value: ThemeMode.light, label: Text(l.themeLight)),
                        ButtonSegment(value: ThemeMode.dark, label: Text(l.themeDark)),
                      ],
                    ),
                    MyAppsSettingsSegmentRow<AppUiStyle>(
                      leading: const Icon(Icons.palette_outlined),
                      title: l.style,
                      selected: {prefs.style},
                      onSelectionChanged: (v) => prefs.style = v.first,
                      segments: const [
                        ButtonSegment(value: AppUiStyle.expressive, label: Text('Expressive')),
                        ButtonSegment(value: AppUiStyle.material3, label: Text('Material 3')),
                      ],
                    ),
                    // As in MyAnime: bottom everywhere, the side on wide
                    // windows (the default), or the side everywhere; and
                    // which side, for either side option.
                    MyAppsSettingsSegmentRow<NavPlacement>(
                      leading: const Icon(Icons.view_sidebar_outlined),
                      title: l.settingsNavPlacement,
                      description: l.settingsNavPlacementDesc,
                      selected: {prefs.navPlacement},
                      onSelectionChanged: (v) => prefs.navPlacement = v.first,
                      segments: [
                        ButtonSegment(value: NavPlacement.bottom, label: Text(l.settingsNavPlacementBottom)),
                        ButtonSegment(value: NavPlacement.sideOnWide, label: Text(l.settingsNavPlacementSideOnWide)),
                        ButtonSegment(value: NavPlacement.side, label: Text(l.settingsNavPlacementSide)),
                      ],
                    ),
                    if (prefs.navPlacement != NavPlacement.bottom)
                      MyAppsSettingsSegmentRow<bool>(
                        leading: const Icon(Icons.swap_horiz),
                        title: l.settingsRailSide,
                        description: l.settingsRailSideDesc,
                        selected: {prefs.railOnRight},
                        onSelectionChanged: (v) => prefs.railOnRight = v.first,
                        segments: [
                          ButtonSegment(
                            value: false,
                            icon: const Icon(Icons.align_horizontal_left, size: 18),
                            label: Text(l.settingsRailSideLeft),
                          ),
                          ButtonSegment(
                            value: true,
                            icon: const Icon(Icons.align_horizontal_right, size: 18),
                            label: Text(l.settingsRailSideRight),
                          ),
                        ],
                      ),
                    SwitchListTile(
                      title: Text(l.dynamicColor),
                      subtitle: Text(l.dynamicColorHint),
                      value: prefs.dynamicColor,
                      onChanged: (v) => prefs.dynamicColor = v,
                    ),
                    ListTile(
                      title: Text(l.language),
                      trailing: DropdownButton<String?>(
                        value: prefs.locale,
                        underline: const SizedBox(),
                        onChanged: (v) => prefs.locale = v,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l.themeSystem)),
                          const DropdownMenuItem(value: 'en', child: Text('English')),
                          const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                          const DropdownMenuItem(value: 'zh_TW', child: Text('繁體中文')),
                          const DropdownMenuItem(value: 'ja', child: Text('日本語')),
                        ],
                      ),
                    ),
                  ],
                ),
                MyAppsSettingsSection(
                  title: l.sectionInput,
                  children: [
                    ListTile(
                      title: Text(l.pointerSpeed),
                      subtitle: Slider(
                        min: 0.6,
                        max: 3,
                        divisions: 12,
                        value: prefs.pointerSpeed.clamp(0.6, 3),
                        label: prefs.pointerSpeed.toStringAsFixed(1),
                        onChanged: (v) => prefs.pointerSpeed = v,
                      ),
                    ),
                    CursorSizeTile(prefs: prefs),
                    SwitchListTile(
                      title: Text(l.splitKeyboard),
                      subtitle: Text(l.splitKeyboardHint),
                      value: prefs.splitKeyboard,
                      onChanged: (v) => prefs.splitKeyboard = v,
                    ),
                    SwitchListTile(
                      title: Text(l.pictureTop),
                      subtitle: Text(l.pictureTopHint),
                      value: prefs.pictureTop,
                      onChanged: (v) => prefs.pictureTop = v,
                    ),
                    SwitchListTile(
                      title: Text(l.laptopMode),
                      subtitle: Text(l.laptopModeHint),
                      value: prefs.laptopMode,
                      onChanged: (v) => prefs.laptopMode = v,
                    ),
                    if (prefs.laptopMode)
                      SwitchListTile(
                        title: Text(l.laptopSafeArea),
                        subtitle: Text(l.laptopSafeAreaHint),
                        value: prefs.laptopSafeArea,
                        onChanged: (v) => prefs.laptopSafeArea = v,
                      ),
                  ],
                ),
                MyAppsSettingsSection(
                  title: l.sectionAbout,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(l.aboutVersion),
                      subtitle: Text('${l.aboutApp} · $buildCommit · $buildTime'),
                      trailing: Text('$appVersion ($buildNumber)', style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.memory_outlined),
                      title: Text(l.aboutCore),
                      subtitle: Text(l.aboutCoreHint),
                      trailing: Text(status.version.isEmpty ? '–' : status.version, style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                    _row(SettingsDetail.diagnostics, icon: Icons.bug_report_outlined, title: l.diagnostics, subtitle: l.diagnosticsHint),
                    _row(SettingsDetail.license, icon: Icons.gavel_outlined, title: l.aboutLicense),
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(l.aboutLicenses),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: l.aboutApp,
                        applicationVersion: '$appVersion · Kyokai Core ${status.version}',
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
    );
  }

}

/// This device's sign-in keys: hosts that hold the public half let this
/// phone in without a password.
class KeysPage extends StatefulWidget {
  const KeysPage({super.key});

  @override
  State<KeysPage> createState() => _KeysPageState();
}

class _KeysPageState extends State<KeysPage> {
  List<Map<String, Object?>> _keys = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final r = await AppScope.of(context).engine.call<List<Object?>>('keys.list');
    if (mounted) setState(() => _keys = r.map((e) => (e as Map).cast<String, Object?>()).toList());
  }

  /// New key, a key file, or a key pasted.
  Future<void> _add() async {
    final l = context.l;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(l.keyNew),
              subtitle: Text(l.keyNewHint),
              onTap: () => Navigator.pop(context, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: Text(l.keyImportFile),
              subtitle: Text(l.keyImportHint),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: Text(l.keyImportPaste),
              onTap: () => Navigator.pop(context, 'paste'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'new':
        await _generate();
      case 'file':
        final r = await FilePicker.platform.pickFiles(withData: true);
        final f = r?.files.singleOrNull;
        final bytes = f?.bytes;
        if (f == null || bytes == null || !mounted) return;
        if (bytes.length > 64 * 1024) return _failed(KeyImportError.notAKey);
        await _import(utf8.decode(bytes, allowMalformed: true), f.name.replaceAll(RegExp(r'\.(pem|key|txt)$'), ''));
      case 'paste':
        final text = await _ask(context, l.keyImportPaste, '', hint: l.keyImportHint, lines: 6);
        if (text != null && text.isNotEmpty && mounted) await _import(text, '');
    }
  }

  Future<void> _import(String text, String name) async {
    final l = context.l;
    final engine = AppScope.of(context).engine;
    final String private;
    try {
      private = importPrivateKey(text);
    } on KeyImportException catch (e) {
      return _failed(e.error);
    }
    final named = await _ask(context, l.keyName, name);
    if (named == null || !mounted) return;
    try {
      await engine.call<Object?>('keys.add', {'name': named, 'private': private});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  void _failed(KeyImportError e) {
    final l = context.l;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (e) {
          KeyImportError.notAKey => l.keyNotAKey,
          KeyImportError.locked => l.keyLocked,
          KeyImportError.unsupported => l.keyUnsupported,
        }),
      ),
    );
  }

  Future<void> _generate() async {
    final l = context.l;
    final engine = AppScope.of(context).engine;
    final name = await _ask(context, l.keyName, AppScope.of(context).engine.status.name);
    if (name == null) return;
    // An Ed25519 key is its 32-byte seed; the core derives the rest.
    final rnd = Random.secure();
    final seed = List<int>.generate(32, (_) => rnd.nextInt(256));
    try {
      await engine.call<Object?>('keys.add', {'name': name, 'private': base64Encode(seed)});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    seed.fillRange(0, 32, 0);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(title: Text(l.signInKeys)),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: Text(l.keyAdd)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(l.signInKeysExplain)),
          for (final k in _keys)
            ListTile(
              leading: const Icon(Icons.key),
              title: Text('${k['name']}'),
              subtitle: Text('${k['type']} · ${k['id']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: '${k['public']}'));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.publicKeyCopied)));
              },
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  final engine = AppScope.of(context).engine;
                  if (v == 'share') await Share.share('${k['public']}');
                  if (v == 'remove') {
                    await engine.call<Object?>('keys.remove', {'id': k['id']});
                    await _load();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'share', child: Text(l.sharePublicKey)),
                  PopupMenuItem(value: 'remove', child: Text(l.remove)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<String?> _ask(BuildContext context, String title, String initial, {String? hint, bool secret = false, int lines = 1}) {
  final l = context.l;
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: secret,
        maxLines: secret ? 1 : lines,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(l.ok)),
      ],
    ),
  );
}
