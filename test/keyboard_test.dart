import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/ui/keyboard/keyboard.dart';
import 'package:kyokai_mobile/ui/keyboard/keys.dart';

class _Sent {
  final events = <(int, bool)>[];
  void call(int code, bool down, {required bool caps}) => events.add((code, down));
}

Future<_Sent> _pump(WidgetTester t, {double width = 390, HostOs os = HostOs.windows, bool split = false}) async {
  final sent = _Sent();
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: RemoteKeyboard(send: sent.call, onHide: () {}, hostOs: os, split: split, onSplitChanged: (_) {}),
      ),
    ),
  ));
  return sent;
}

void main() {
  test('keysyms follow Shift', () {
    expect(keysymFor(usKeys['a']!.$1, shift: false), 0x61);
    expect(keysymFor(usKeys['a']!.$1, shift: true), 0x41);
    expect(keysymFor(usKeys['1']!.$1, shift: true), '!'.codeUnitAt(0));
    expect(keysymFor(Scan.enter, shift: false), 0xFF0D);
    expect(keysymFor(Scan.f(12), shift: false), 0xFFC9);
  });

  test('host OS from a status string', () {
    expect(HostOs.parse('macOS 15.2'), HostOs.macos);
    expect(HostOs.parse('linux'), HostOs.linux);
    expect(HostOs.parse('Windows 11'), HostOs.windows);
    expect(HostOs.parse(null), HostOs.windows);
  });

  testWidgets('a letter is its scan code, down then up', (t) async {
    final sent = await _pump(t);
    await t.tap(find.text('q'));
    expect(sent.events, [(0x10, true), (0x10, false)]);
  });

  testWidgets('Ctrl tapped latches for the next key only', (t) async {
    final sent = await _pump(t);
    await t.tap(find.text('Ctrl'));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('c'));
    expect(sent.events, [(Scan.lctrl, true), (0x2E, true), (0x2E, false), (Scan.lctrl, false)]);
    sent.events.clear();
    await t.tap(find.text('c'));
    expect(sent.events, [(0x2E, true), (0x2E, false)]);
  });

  testWidgets('a Mac host gets Mac modifiers in Mac order', (t) async {
    await _pump(t, os: HostOs.macos);
    final ctrl = t.getTopLeft(find.text('⌃ Ctrl')).dx;
    final opt = t.getTopLeft(find.text('⌥ Opt')).dx;
    final cmd = t.getTopLeft(find.text('⌘ Cmd')).dx;
    expect(ctrl < opt && opt < cmd, isTrue);
    expect(find.text('Win'), findsNothing);
  });

  testWidgets('Linux names the Win key Super', (t) async {
    await _pump(t, os: HostOs.linux);
    expect(find.text('Super'), findsOneWidget);
  });

  testWidgets('wide screens get the full keyboard, or the split one with a touchpad', (t) async {
    await _pump(t, width: 1024);
    expect(find.text('`'), findsOneWidget);
    expect(find.text('Touchpad'), findsNothing);
    await _pump(t, width: 1024, split: true);
    expect(find.text('Touchpad'), findsOneWidget);
    expect(find.text('q'), findsOneWidget);
    expect(find.text('p'), findsOneWidget);
  });

  testWidgets('Fn page has the host shortcuts', (t) async {
    final sent = await _pump(t, os: HostOs.macos);
    await t.tap(find.text('Fn'));
    await t.pump();
    expect(find.text('F12'), findsOneWidget);
    await t.tap(find.text('⌘C'));
    expect(sent.events, [(Scan.lwin, true), (0x2E, true), (0x2E, false), (Scan.lwin, false)]);
  });

  testWidgets('every layout fits without overflow', (t) async {
    for (final w in [360.0, 390.0, 600.0, 904.0, 1280.0]) {
      for (final split in [false, true]) {
        for (final os in HostOs.values) {
          await _pump(t, width: w, os: os, split: split);
          expect(t.takeException(), isNull, reason: '$w $split $os');
          await t.tap(find.text('Fn'));
          await t.pump();
          expect(t.takeException(), isNull, reason: 'Fn $w $split $os');
        }
      }
    }
  });
}
