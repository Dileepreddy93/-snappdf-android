import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/files/workspace.dart';
import '../../core/platform/native_api.dart';
import '../../core/providers.dart';

/// Saved signatures, encrypted at rest with a hardware-backed Android
/// Keystore key. They never leave the device unless the user exports them.
class SignatureLibrary {
  SignatureLibrary(this._api, this._ws);
  final NativeApi _api;
  final Workspace _ws;
  static const _prefix = 'sig_';

  Future<List<String>> list() async =>
      (await _api.secureList()).where((n) => n.startsWith(_prefix)).toList().reversed.toList();

  Future<Uint8List?> read(String id) => _api.secureRead(id);

  Future<String> save(Uint8List png) async {
    final id = '$_prefix${DateTime.now().millisecondsSinceEpoch}';
    await _api.secureWrite(id, png);
    return id;
  }

  Future<void> delete(String id) => _api.secureDelete(id);

  /// Decrypts into a private temporary file for placing into a PDF.
  Future<String> toTempFile(String id) async {
    final bytes = await read(id);
    if (bytes == null) throw StateError('Signature not found');
    final dir = await _ws.newWorkDir();
    final path = p.join(dir.path, 'signature.png');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
}

final signatureLibraryProvider = Provider<SignatureLibrary>(
  (ref) => SignatureLibrary(ref.watch(nativeApiProvider), ref.watch(workspaceProvider)),
);

/// Bumped when signatures are added or removed so lists refresh.
final signatureListProvider = FutureProvider<List<String>>((ref) => ref.watch(signatureLibraryProvider).list());
