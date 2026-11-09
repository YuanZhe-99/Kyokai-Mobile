// The host's AI on a page of its own (from a device's details).

import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../shell/app.dart';
import 'ai_panel.dart';

class AiPage extends StatelessWidget {
  const AiPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final host = AppScope.of(context).engine.status.host(deviceId);
    return Scaffold(
      appBar: AppBar(title: Text(host?.title ?? context.l.aiTask)),
      body: SafeArea(top: false, child: AiPanel(deviceId: deviceId)),
    );
  }
}
