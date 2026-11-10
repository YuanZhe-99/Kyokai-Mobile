import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kyokai_mobile/core/clients.dart';
import 'package:kyokai_mobile/data/services.dart';
import 'package:kyokai_mobile/l10n/gen/app_localizations.dart';
import 'package:kyokai_mobile/ui/services/files_page.dart';

Uint8List _p(int kind, Map<String, Object?> body) => Uint8List.fromList([kind, ...utf8.encode(jsonEncode(body))]);

/// An SFTP server in memory: folders by path, each a list of entries.
class _FakeFiles extends FilesSession {
  _FakeFiles({this.fail}) : super('123456789', 'Box');

  /// A reason sftp.open fails with, else it connects.
  final String? fail;

  final dirs = <String, List<Map<String, Object?>>>{
    '/home/me': [
      {'name': 'a.txt', 'size': 2048, 'modified': 1700000000},
      {'name': 'docs', 'dir': true, 'modified': 1700000000},
    ],
    '/home/me/docs': [],
  };
  final calls = <(String, Map<String, Object?>)>[];
  int _next = 0;

  @override
  Future<void> open({ServiceSignIn? signIn, String? trust, String locale = 'en', int width = 0, int height = 0}) async {
    id = 1;
    packetForTest(_p(ClientPacket.state, fail == null ? {'state': 'connected'} : {'state': 'failed', 'error': fail}));
  }

  @override
  Future<Map<String, Object?>> request(String method, Map<String, Object?> params) async {
    calls.add((method, params));
    String name(String p) => p.substring(p.lastIndexOf('/') + 1);
    String parent(String p) => p.substring(0, p.lastIndexOf('/'));
    switch (method) {
      case 'sftp.list':
        final p = '${params['path']}' == '' ? '/home/me' : '${params['path']}';
        final d = dirs[p];
        if (d == null) throw ClientsError('not-found');
        // Folders first, as the library sorts them.
        final sorted = [...d]..sort((a, b) => (b['dir'] == true ? 1 : 0) - (a['dir'] == true ? 1 : 0));
        return {'path': p, 'entries': sorted};
      case 'sftp.mkdir':
        final p = '${params['path']}';
        dirs[parent(p)]!.add({'name': name(p), 'dir': true, 'modified': 1700000000});
        dirs[p] = [];
        return {};
      case 'sftp.remove':
        final p = '${params['path']}';
        dirs[parent(p)]!.removeWhere((e) => e['name'] == name(p));
        return {};
      case 'sftp.download' || 'sftp.upload':
        return {'transfer': ++_next};
    }
    return {};
  }

  void transfer(int n, String state, {int done = 0, int total = 0, String? error}) => packetForTest(
    _p(ClientPacket.transfer, {'transfer': n, 'done': done, 'total': total, 'state': state, 'error': ?error}),
  );
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

Future<_FakeFiles> _open(WidgetTester t, {String? fail, List<PickedFile> pick = const [], List<String>? shared}) async {
  final s = _FakeFiles(fail: fail);
  await s.open();
  await t.pumpWidget(
    _app(
      FilesPage(
        session: s,
        pickFiles: () async => pick,
        saveFile: (_, _) async => true,
        shareFile: (path) async => shared?.add(path),
        downloads: () async => '/data/cache/downloads',
      ),
    ),
  );
  await t.pumpAndSettle();
  return s;
}

void main() {
  testWidgets('lists the home folder, folders first, and goes into a folder and up again', (t) async {
    final s = await _open(t);
    expect(find.text('/home/me'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(t.getTopLeft(find.text('docs')).dy, lessThan(t.getTopLeft(find.text('a.txt')).dy));

    await t.tap(find.text('docs'));
    await t.pumpAndSettle();
    expect(s.path, '/home/me/docs');
    expect(find.text('This folder is empty'), findsOneWidget);

    await t.tap(find.byTooltip('Up'));
    await t.pumpAndSettle();
    expect(s.path, '/home/me');
    expect(find.text('a.txt'), findsOneWidget);
  });

  testWidgets('a new folder, and a file deleted after asking', (t) async {
    final s = await _open(t);
    await t.tap(find.byTooltip('New folder'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'photos');
    await t.pump();
    await t.tap(find.text('Create'));
    await t.pumpAndSettle();
    expect(s.calls.any((c) => c.$1 == 'sftp.mkdir' && c.$2['path'] == '/home/me/photos'), isTrue);
    expect(find.text('photos'), findsOneWidget);

    await t.longPress(find.text('a.txt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete').last);
    await t.pumpAndSettle();
    expect(find.text('Delete a.txt?'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Delete'));
    await t.pumpAndSettle();
    expect(s.calls.any((c) => c.$1 == 'sftp.remove' && c.$2['path'] == '/home/me/a.txt'), isTrue);
    expect(find.text('a.txt'), findsNothing);
  });

  testWidgets('a download goes into the app\'s storage, shows its progress and is offered to share', (t) async {
    final shared = <String>[];
    final s = await _open(t, shared: shared);
    await t.tap(find.byType(PopupMenuButton<VoidCallback>).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Download'));
    await t.pumpAndSettle();
    final call = s.calls.lastWhere((c) => c.$1 == 'sftp.download');
    expect(call.$2['remote'], '/home/me/a.txt');
    expect('${call.$2['local']}', startsWith('/data/cache/downloads/'));
    expect('${call.$2['local']}', endsWith('/a.txt'));

    s.transfer(1, 'running', done: 1024, total: 2048);
    await t.pump();
    await t.tap(find.byTooltip('Transfers'));
    await t.pumpAndSettle();
    expect(find.text('1.0 KB of 2.0 KB'), findsOneWidget);
    final bar = t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).last);
    expect(bar.value, 0.5);

    s.transfer(1, 'done', done: 2048, total: 2048);
    await t.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('a.txt downloaded'), findsOneWidget);
    await t.tap(find.byTooltip('Share'));
    await t.pumpAndSettle();
    expect(shared, [call.$2['local']]);
  });

  testWidgets('an upload takes a free name in the folder shown, and can be cancelled', (t) async {
    final s = await _open(t, pick: [(path: '/data/cache/picked/a.txt', name: 'a.txt')]);
    await t.tap(find.byTooltip('Upload'));
    await t.pumpAndSettle();
    final call = s.calls.lastWhere((c) => c.$1 == 'sftp.upload');
    expect(call.$2['local'], '/data/cache/picked/a.txt');
    expect(call.$2['remote'], '/home/me/a (2).txt');

    s.transfer(1, 'running', done: 10, total: 100);
    await t.pump();
    await t.tap(find.byTooltip('Transfers'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Cancel'));
    await t.pumpAndSettle();
    expect((s.calls.last.$1, s.calls.last.$2['transfer']), ('sftp.cancel', 1));
    s.transfer(1, 'cancelled', done: 10, total: 100);
    await t.pumpAndSettle();
    expect(find.text('Cancelled'), findsOneWidget);
  });

  testWidgets('a failed transfer says why', (t) async {
    final s = await _open(t);
    await s.download(s.entries.firstWhere((e) => !e.dir), '/data/cache/downloads/1/a.txt');
    s.transfer(1, 'failed', error: 'permission-denied');
    await t.pump();
    await t.tap(find.byTooltip('Transfers'));
    await t.pumpAndSettle();
    expect(find.text("You don't have permission to do that on the server."), findsOneWidget);
  });

  testWidgets('a server without SFTP says so and offers to try again', (t) async {
    await _open(t, fail: 'no-sftp');
    expect(find.text("This computer's SSH server does not offer file access (SFTP)."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byTooltip('Upload'), findsNothing);
  });
}
