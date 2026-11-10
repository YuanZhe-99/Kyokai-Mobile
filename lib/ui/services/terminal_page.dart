// A device's SSH shell: the terminal, the keys a phone keyboard lacks above
// the keyboard, and what to do when it could not connect.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../data/services.dart';
import '../shell/app.dart';
import 'service_open.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.session});
  final ServiceSession session;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _focus = FocusNode();
  final _controller = TerminalController();

  ServiceSession get s => widget.session;

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _key(TerminalKey key) {
    HapticFeedback.selectionClick();
    s.terminal.keyInput(key, ctrl: s.ctrl, alt: s.alt);
    if (s.ctrl || s.alt) setState(() => s.ctrl = s.alt = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        Widget extra(String label, VoidCallback onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: on ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minWidth: 44),
                height: 38,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: on ? cs.onPrimaryContainer : cs.onSurface)),
              ),
            ),
          ),
        );
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(s.title),
            actions: [
              IconButton(
                tooltip: l.paste,
                onPressed: () async {
                  final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                  if (t != null && t.isNotEmpty) s.terminal.paste(t);
                },
                icon: const Icon(Icons.content_paste),
              ),
              IconButton(
                tooltip: l.disconnect,
                onPressed: () => disconnectService(context, s),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: TerminalView(
                          s.terminal,
                          controller: _controller,
                          focusNode: _focus,
                          autofocus: true,
                          keyboardType: TextInputType.visiblePassword,
                          theme: TerminalThemes.whiteOnBlack,
                          textStyle: const TerminalStyle(fontSize: 13),
                          padding: const EdgeInsets.all(4),
                          deleteDetection: true,
                        ),
                      ),
                      if (!s.connected) Positioned.fill(child: _StateCard(session: s)),
                    ],
                  ),
                ),
                if (s.connected)
                  Container(
                    color: cs.surfaceContainer,
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          extra('Esc', () => _key(TerminalKey.escape)),
                          extra('Tab', () => _key(TerminalKey.tab)),
                          extra('Ctrl', () => setState(() => s.ctrl = !s.ctrl), on: s.ctrl),
                          extra('Alt', () => setState(() => s.alt = !s.alt), on: s.alt),
                          extra('←', () => _key(TerminalKey.arrowLeft)),
                          extra('↑', () => _key(TerminalKey.arrowUp)),
                          extra('↓', () => _key(TerminalKey.arrowDown)),
                          extra('→', () => _key(TerminalKey.arrowRight)),
                          for (final c in const ['|', '~', '/', '-', '_', r'$'])
                            extra(c, () => s.terminal.textInput(c)),
                          extra('Home', () => _key(TerminalKey.home)),
                          extra('End', () => _key(TerminalKey.end)),
                          extra('PgUp', () => _key(TerminalKey.pageUp)),
                          extra('PgDn', () => _key(TerminalKey.pageDown)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Connecting, or why it is not connected, with what to do.
class _StateCard extends StatelessWidget {
  const _StateCard({required this.session});
  final ServiceSession session;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final s = session;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: s.state == 'connecting'
                  ? [const CircularProgressIndicator(), const SizedBox(height: 16), Text(l.connecting)]
                  : [
                      Icon(s.state == 'failed' ? Icons.error_outline : Icons.link_off, size: 40, color: cs.error),
                      const SizedBox(height: 12),
                      Text(serviceErrorText(l, s.error), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: () => retryService(context, s), child: Text(l.tryAgain)),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The same card for the picture pages.
class ServiceStateCard extends StatelessWidget {
  const ServiceStateCard({super.key, required this.session});
  final ServiceSession session;

  @override
  Widget build(BuildContext context) => _StateCard(session: session);
}
