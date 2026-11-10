// The host's AI task, driven from here: start one, follow it, answer its
// approvals, reply, pause, resume, stop. The task runs on the host with the
// host's own provider and policy (third_party/kyokai doc computer-use.md);
// this side only sends the AI link's control messages.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/sessions.dart';
import '../home/device_widgets.dart';
import '../shell/app.dart';
import '../viewer/session_sheets.dart';
import 'ai_history.dart';

class AiPanel extends StatefulWidget {
  const AiPanel({super.key, required this.deviceId, this.onClose});
  final String deviceId;
  final VoidCallback? onClose;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  RemoteSession? _s;
  final _input = TextEditingController();
  String _thinking = 'medium';
  Timer? _draft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final s = await AppScope.of(context).sessions.connect(widget.deviceId, kind: SessionKind.ai);
    if (!mounted) return;
    setState(() => _s = s);
  }

  @override
  void dispose() {
    _draft?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final s = _s;
    final text = _input.text.trim();
    if (s == null || text.isEmpty) return;
    final task = s.aiTask;
    final live = task != null && const {'running', 'approval', 'paused'}.contains(task['state']);
    if (live) {
      s.aiCommand('reply', text: text);
    } else {
      s.aiStart(text, thinking: _thinking);
    }
    _input.clear();
    s.setAiDraft('');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = _s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(l.aiOnHost, style: tt.titleMedium)),
              IconButton(
                key: const ValueKey('aiHistory'),
                tooltip: l.aiHistory,
                onPressed: () => showAiHistory(context, widget.deviceId),
                icon: const Icon(Icons.history),
              ),
              if (widget.onClose != null) IconButton(tooltip: MaterialLocalizations.of(context).closeButtonTooltip, onPressed: widget.onClose, icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Expanded(
          child: s == null
              ? const Center(child: CircularProgressIndicator())
              : ListenableBuilder(listenable: s, builder: (context, _) => _content(context, s)),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, RemoteSession s) {
    final l = context.l;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (!s.connected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.state == 'connecting' || s.state == 'confirming' || s.state == 'reconnecting') ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(s.confirming ? l.aiConfirming : l.connecting, textAlign: TextAlign.center),
              ] else ...[
                Text(s.state == 'closed' ? l.sessionEnded : (s.dialError ?? failureText(l, s.failure)), textAlign: TextAlign.center),
                const SizedBox(height: 12),
              ],
              if (!s.connected && s.state != 'connecting')
                TextButton(
                  onPressed: () async {
                    final r = await askPassword(context, s);
                    if (r != null) await s.retry(r.$1, remember: r.$2);
                  },
                  child: Text(l.typePassword),
                ),
            ],
          ),
        ),
      );
    }
    if (!s.mayRunAi && !s.mayApprove) return Center(child: Text(l.aiNotAllowed));
    final task = s.aiTask;
    final state = task?['state'] as String?;
    final live = const {'running', 'approval', 'paused'}.contains(state);
    final approval = task?['approval'] as Map?;
    final steps = (task?['steps'] as List?) ?? const [];
    final progress = (task?['progress'] as List?) ?? const [];
    final (chipText, chipBg, chipFg) = switch (state) {
      'running' => (l.aiRunning, cs.primaryContainer, cs.onPrimaryContainer),
      'approval' => (l.aiWaitingApproval, cs.tertiaryContainer, cs.onTertiaryContainer),
      'paused' => (l.aiPaused, cs.secondaryContainer, cs.onSecondaryContainer),
      'done' => (l.aiDone, cs.surfaceContainerHighest, cs.onSurfaceVariant),
      'failed' => (l.aiFailed, cs.errorContainer, cs.onErrorContainer),
      'cancelled' => (l.aiCancelled, cs.surfaceContainerHighest, cs.onSurfaceVariant),
      _ => ('', cs.surface, cs.onSurface),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            children: [
              if (task == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(l.aiNoTask, style: TextStyle(color: cs.onSurfaceVariant)),
                )
              else ...[
                Row(
                  children: [
                    Expanded(child: Text('${task['name'] ?? task['instruction'] ?? ''}', style: tt.titleSmall)),
                    if (chipText.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(8)),
                        child: Text(chipText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: chipFg)),
                      ),
                  ],
                ),
                if (task['paused'] != null)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.aiPausedBy('${task['paused']}'), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                if ((task['text'] as String?)?.isNotEmpty ?? false)
                  Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('${task['text']}')),
                for (final p in progress)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text('· $p', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13))),
                if (approval != null && state == 'approval')
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if ((approval['flagged'] as List?)?.isNotEmpty ?? false)
                          Text(l.aiAsksBefore((approval['flagged'] as List).join(', ')), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text(describeAction(approval['action']), style: const TextStyle(fontWeight: FontWeight.w500)),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: FilledButton(onPressed: s.mayApprove ? () => s.aiDecide(true) : null, child: Text(l.approve))),
                            const SizedBox(width: 8),
                            Expanded(child: OutlinedButton(onPressed: s.mayApprove ? () => s.aiDecide(false) : null, child: Text(l.decline))),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (steps.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(l.aiSteps, style: tt.labelLarge),
                  for (final st in steps.reversed.take(10))
                    if (st is Map)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(switch (st['outcome']) {
                          'ok' => Icons.check_circle_outline,
                          'declined' => Icons.block,
                          'failed' => Icons.error_outline,
                          _ => Icons.radio_button_unchecked,
                        }, size: 18),
                        title: Text(describeAction(st['action']), maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: st['detail'] == null ? null : Text('${st['detail']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                ],
                if (task['error'] != null)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text('${task['error']}', style: TextStyle(color: cs.error))),
              ],
              if (s.aiError != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(s.aiError!, style: TextStyle(color: cs.error))),
            ],
          ),
        ),
        if (live && s.mayRunAi)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (state == 'paused')
                  FilledButton.tonal(onPressed: () => s.aiCommand('resume'), child: Text(l.aiResume))
                else
                  FilledButton.tonal(onPressed: () => s.aiCommand('pause'), child: Text(l.aiPause)),
                const SizedBox(width: 8),
                FilledButton.tonal(onPressed: () => s.aiCommand('cancel'), child: Text(l.aiStop)),
              ],
            ),
          ),
        if (s.mayRunAi)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!live)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: 'low', label: Text(l.thinkLow)),
                        ButtonSegment(value: 'medium', label: Text(l.thinkMedium)),
                        ButtonSegment(value: 'high', label: Text(l.thinkHigh)),
                      ],
                      selected: {_thinking},
                      onSelectionChanged: (v) => setState(() => _thinking = v.first),
                    ),
                  ),
                TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onChanged: (v) {
                    _draft?.cancel();
                    _draft = Timer(const Duration(milliseconds: 400), () => s.setAiDraft(v));
                  },
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: live ? l.aiReplyHint : l.aiTaskHint,
                    suffixIcon: IconButton(tooltip: l.aiSend, onPressed: _submit, icon: const Icon(Icons.send)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One AI action in words: `click (0.42, 0.31)`, `type "hello"`, …
String describeAction(Object? action) {
  if (action is! Map) return '';
  final kind = '${action['kind'] ?? action['type'] ?? ''}';
  final rest = Map.of(action)..remove('kind');
  final text = rest['text'];
  if (text is String) return '$kind "${text.length > 60 ? '${text.substring(0, 60)}…' : text}"';
  final parts = rest.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  return parts.isEmpty ? kind : '$kind ($parts)';
}
