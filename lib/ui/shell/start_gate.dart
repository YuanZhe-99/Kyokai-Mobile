// Shown until the core has started; if it cannot, says why and offers the
// diagnostics and logs, which are what the developer needs to fix it.

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../settings/diagnostics_page.dart';
import 'app.dart';

class StartGate extends StatelessWidget {
  const StartGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).engine;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        if (engine.started) return child;
        final l = context.l;
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: engine.error == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(l.starting, style: Theme.of(context).textTheme.titleMedium),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline, size: 48, color: cs.error),
                          const SizedBox(height: 16),
                          Text(l.startFailed, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                          const SizedBox(height: 8),
                          SelectableText(engine.error!, textAlign: TextAlign.center),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
                            ),
                            icon: const Icon(Icons.bug_report_outlined),
                            label: Text(l.diagnostics),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
