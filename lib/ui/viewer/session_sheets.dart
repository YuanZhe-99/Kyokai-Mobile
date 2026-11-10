// The viewer's sheets and dialogs: password, displays, quality, the
// session menu (actions, sound, clipboard) and typing text.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/sessions.dart';
import '../shell/app.dart';

/// Asks for the host's password: (password, remember) or null.
Future<(String, bool)?> askPassword(BuildContext context, RemoteSession s) {
  final l = context.l;
  final c = TextEditingController();
  var remember = true;
  var hide = true;
  return showDialog<(String, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(l.passwordFor(s.title)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.passwordHint),
            const SizedBox(height: 16),
            TextField(
              controller: c,
              autofocus: true,
              obscureText: hide,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l.password,
                suffixIcon: IconButton(
                  onPressed: () => set(() => hide = !hide),
                  icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, (v, remember)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: remember,
              onChanged: (v) => set(() => remember = v ?? false),
              title: Text(l.rememberPassword),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, (c.text, remember)), child: Text(l.connect)),
        ],
      ),
    ),
  );
}

Future<void> showDisplays(BuildContext context, RemoteSession s) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (ctx) {
    final l = ctx.l;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text(l.displays, style: Theme.of(ctx).textTheme.titleMedium)),
          for (final (i, d) in s.displays.indexed)
            ListTile(
              leading: Icon(i == s.display ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(l.displayN(i + 1) + (d['primary'] == true ? ' · ${l.primary}' : '')),
              subtitle: Text('${d['width']}×${d['height']}'),
              onTap: () {
                s.showDisplay(i);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  },
);

Future<void> showQuality(BuildContext context, RemoteSession s) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => ListenableBuilder(
    listenable: s,
    builder: (ctx, _) {
      final l = ctx.l;
      final q = s.quality;
      Widget row(String title, Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(title, style: Theme.of(ctx).textTheme.labelLarge), const SizedBox(height: 8), child],
        ),
      );
      final codecs = ['auto', ...s.codecs.where((c) => c == 'h264' || c == 'hevc')];
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(
                l.qualityPreset,
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'speed', label: Text(l.qualitySpeed)),
                    ButtonSegment(value: 'balanced', label: Text(l.qualityBalanced)),
                    ButtonSegment(value: 'best', label: Text(l.qualityBest)),
                  ],
                  selected: {q.preset == 'custom' ? 'balanced' : q.preset},
                  onSelectionChanged: (v) => s.setQuality(q.copyWith(preset: v.first)),
                ),
              ),
              row(
                l.qualityResolution,
                Wrap(
                  spacing: 8,
                  children: [
                    for (final size in ['auto', '2160', '1440', '1080', '720'])
                      ChoiceChip(
                        label: Text(size == 'auto' ? l.auto : '${size}p'),
                        selected: q.size == size,
                        onSelected: (_) => s.setQuality(q.copyWith(size: size)),
                      ),
                  ],
                ),
              ),
              row(
                l.qualityFps,
                Wrap(
                  spacing: 8,
                  children: [
                    for (final fps in [15, 30, 60])
                      ChoiceChip(
                        label: Text('$fps'),
                        selected: q.fps == fps,
                        onSelected: (_) => s.setQuality(q.copyWith(fps: fps)),
                      ),
                  ],
                ),
              ),
              row(
                l.qualityCodec,
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in codecs)
                      ChoiceChip(
                        label: Text(c == 'auto' ? l.auto : c.toUpperCase()),
                        selected: q.codec == c,
                        onSelected: (_) => s.setQuality(q.copyWith(codec: c)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  ),
);

Future<void> showSessionMenu(
  BuildContext context,
  RemoteSession s, {
  required VoidCallback onQuality,
  required VoidCallback onAi,
  required VoidCallback onTypeText,
  required Future<void> Function() onDisconnect,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => ListenableBuilder(
    listenable: s,
    builder: (ctx, _) {
      final l = ctx.l;
      final prefs = AppScope.of(ctx).prefs;
      final a = s.actions;
      void act(String name) {
        s.action(name);
        Navigator.pop(ctx);
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              ListTile(leading: const Icon(Icons.tune), title: Text(l.quality), onTap: () {
                Navigator.pop(ctx);
                onQuality();
              }),
              ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: Text(l.aiTask), onTap: () {
                Navigator.pop(ctx);
                onAi();
              }),
              ListTile(leading: const Icon(Icons.text_fields), title: Text(l.typeText), onTap: () {
                Navigator.pop(ctx);
                onTypeText();
              }),
              SwitchListTile(
                secondary: const Icon(Icons.volume_up_outlined),
                title: Text(l.sound),
                value: s.sound,
                onChanged: s.granted.contains('hear-sound') ? s.setSound : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.content_paste),
                title: Text(l.shareClipboard),
                value: s.shareClipboard,
                onChanged: s.granted.contains('clipboard') ? s.setShareClipboard : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.analytics_outlined),
                title: Text(l.showVideoDetails),
                value: prefs.overlay,
                onChanged: (v) => prefs.overlay = v,
              ),
              const Divider(),
              ListTile(leading: const Icon(Icons.light_mode_outlined), title: Text(l.actionWake), subtitle: Text(l.actionWakeHint), onTap: () => act('wake')),
              if (a['ctrl_alt_del'] == true)
                ListTile(leading: const Icon(Icons.keyboard_command_key), title: const Text('Ctrl+Alt+Del'), onTap: () => act('ctrl-alt-del')),
              if (a.isNotEmpty) ListTile(leading: const Icon(Icons.lock_outline), title: Text(l.actionLock), onTap: () => act('lock')),
              if (a.containsKey('blocked'))
                SwitchListTile(
                  secondary: const Icon(Icons.block),
                  title: Text(l.actionBlockInput),
                  value: a['blocked'] == true,
                  onChanged: (v) => act(v ? 'block' : 'unblock'),
                ),
              if (a.containsKey('privacy'))
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: Text(l.actionPrivacy),
                  value: a['privacy'] == true,
                  onChanged: (v) => act(v ? 'privacy-on' : 'privacy-off'),
                ),
              const Divider(),
              ListTile(
                leading: Icon(Icons.link_off, color: Theme.of(ctx).colorScheme.error),
                title: Text(l.disconnect, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  onDisconnect();
                },
              ),
            ],
          ),
        ),
      );
    },
  ),
);

/// Types text on the host as it is (pasted text, or a language the
/// on-screen keyboard has no keys for).
Future<void> typeText(BuildContext context, RemoteSession s) => typeTextInto(context, s.text);

/// Asks for text and gives it to [send] (a Kyokai session, Remote Desktop,
/// VNC).
Future<void> typeTextInto(BuildContext context, void Function(String) send) async {
  final l = context.l;
  final c = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.typeText),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLines: 5,
        minLines: 2,
        decoration: InputDecoration(hintText: l.typeTextHint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(l.send)),
      ],
    ),
  );
  if (text != null && text.isNotEmpty) send(text);
}
