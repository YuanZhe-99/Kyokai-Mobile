// Opening a device's SSH, Remote Desktop or VNC: the sign-in form, what a
// failure means, and the page each one shows in.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/services.dart';
import '../../l10n/gen/app_localizations.dart';
import '../home/device_widgets.dart';
import '../shell/app.dart';
import 'desktop_page.dart';
import 'terminal_page.dart';

/// Opens a service: the saved sign-in when there is one, else the form.
Future<void> openService(BuildContext context, String deviceId, ServiceKind kind, String title, {String? address}) async {
  final state = AppScope.of(context);
  Map<String, Object?> saved = const {};
  try {
    saved = await state.engine.call<Map<String, Object?>>('credentials.get', {'device_id': deviceId, 'service': kind.name});
  } catch (_) {}
  if (!context.mounted) return;
  ServiceSignIn? signIn;
  if ('${saved['method'] ?? ''}'.isEmpty) {
    signIn = await askServiceSignIn(context, kind, saved: saved);
    if (signIn == null || !context.mounted) return;
  }
  final session = ServiceSession(deviceId, kind, title, address: address);
  final locale = Localizations.localeOf(context).toString();
  final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
  // Remote Desktop: the phone's own shape at a readable size.
  final (w, h) = size.width >= size.height ? (1600, (1600 * size.height / size.width).round()) : (1600, 900);
  await session.open(signIn: signIn, locale: locale, width: w, height: h);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => kind == ServiceKind.ssh ? TerminalPage(session: session) : DesktopPage(session: session),
    ),
  );
  await session.close();
  session.dispose();
}

/// Retries after a failure: the form for a sign-in problem, the key for a
/// changed server key, else as before.
Future<void> retryService(BuildContext context, ServiceSession s) async {
  final l = context.l;
  final locale = Localizations.localeOf(context).toString();
  if (s.error == 'host-key-changed' && s.hostKey != null) {
    final trust = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.hostKeyChanged),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.hostKeyChangedHint),
            const SizedBox(height: 12),
            SelectableText(s.hostKey!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.trustKey)),
        ],
      ),
    );
    if (trust == true) await s.open(trust: s.hostKey, locale: locale);
    return;
  }
  ServiceSignIn? signIn;
  if (const {'need-sign-in', 'sign-in-required', 'sign-in-failed', 'no-secure-sign-in', 'password'}.contains(s.error)) {
    signIn = await askServiceSignIn(context, s.kind, problem: serviceErrorText(l, s.error));
    if (signIn == null) return;
  }
  await s.open(signIn: signIn, locale: locale);
}

/// What a service's failure or end means.
String serviceErrorText(AppLocalizations l, String? code) => switch (code) {
  'need-sign-in' => l.svcNeedSignIn,
  'sign-in-required' => l.svcSignInRequired,
  'sign-in-failed' => l.svcSignInFailed,
  'no-answer' => l.svcNoAnswer,
  'no-secure-sign-in' => l.svcNoSecureSignIn,
  'host-key-changed' => l.hostKeyChanged,
  'ended' || 'closed' => l.sessionEnded,
  'replaced' => l.svcReplaced,
  'unreadable' => l.svcUnreadable,
  'unsupported' => l.svcNoTunnel,
  final other => failureText(l, other),
};

/// The sign-in form for a service; null when cancelled.
Future<ServiceSignIn?> askServiceSignIn(
  BuildContext context,
  ServiceKind kind, {
  Map<String, Object?> saved = const {},
  String? problem,
}) => showDialog<ServiceSignIn>(
  context: context,
  builder: (_) => _SignInDialog(kind: kind, saved: saved, problem: problem),
);

class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.kind, required this.saved, this.problem});
  final ServiceKind kind;
  final Map<String, Object?> saved;
  final String? problem;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  late String _method = widget.kind.methods.contains(widget.saved['method'])
      ? '${widget.saved['method']}'
      : widget.kind.methods.first;
  late final _user = TextEditingController(text: '${widget.saved['user'] ?? ''}');
  late final _domain = TextEditingController(text: '${widget.saved['domain'] ?? ''}');
  final _password = TextEditingController();
  bool _remember = true;
  bool _hide = true;

  @override
  void dispose() {
    _user.dispose();
    _domain.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _needsUser => widget.kind == ServiceKind.ssh || _method == 'account';
  bool get _needsPassword => _method == 'password' || _method == 'account';

  String _methodLabel(AppLocalizations l, String m) => switch ((widget.kind, m)) {
    (_, 'key') => l.signInKey,
    (ServiceKind.vnc, 'password') => l.vncPassword,
    (_, 'password') => l.password,
    (ServiceKind.vnc, 'account') => l.macAccount,
    (_, 'account') => l.windowsAccount,
    _ => l.noSignIn,
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(switch (widget.kind) {
        ServiceKind.ssh => l.serviceSsh,
        ServiceKind.rdp => l.serviceRdp,
        ServiceKind.vnc => l.serviceVnc,
      }),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.problem!, style: TextStyle(color: cs.error)),
              ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final m in widget.kind.methods) ButtonSegment(value: m, label: Text(_methodLabel(l, m))),
              ],
              selected: {_method},
              onSelectionChanged: (v) => setState(() => _method = v.first),
            ),
            const SizedBox(height: 12),
            if (_needsUser)
              TextField(
                controller: _user,
                autocorrect: false,
                decoration: InputDecoration(labelText: l.userName),
              ),
            if (widget.kind == ServiceKind.rdp && _method == 'account') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _domain,
                autocorrect: false,
                decoration: InputDecoration(labelText: l.domainOptional),
              ),
            ],
            if (_needsPassword) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: _hide,
                decoration: InputDecoration(
                  labelText: _methodLabel(l, _method == 'account' ? 'password' : _method),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _hide = !_hide),
                    icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  ),
                ),
              ),
            ],
            if (_method == 'key')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.sshKeyHint, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? true),
              title: Text(l.rememberSignIn),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            ServiceSignIn(
              method: _method,
              user: _user.text.trim(),
              domain: _domain.text.trim(),
              password: _needsPassword ? _password.text : '',
              remember: _remember,
            ),
          ),
          child: Text(l.connect),
        ),
      ],
    );
  }
}
