// Handing a file on this phone to the person: saved where they choose
// through the system's dialog, or shared with another app. SFTP downloads
// and clipboard files from the hosts both go this way.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// The largest file the system's save dialog takes here: it is handed the
/// bytes whole.
const saveLimit = 256 << 20;

/// Saves a file where the person chooses; false when they did not.
Future<bool> saveFileAs(String path, String name) async {
  final bytes = await File(path).readAsBytes();
  return await FilePicker.platform.saveFile(fileName: name, bytes: bytes) != null;
}

/// Offers files to other apps.
Future<void> shareFiles(List<String> paths) => Share.shareXFiles([for (final p in paths) XFile(p)]);
