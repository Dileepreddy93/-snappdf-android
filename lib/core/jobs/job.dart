import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../platform/native_api.dart';

/// Tracks one running operation: progress for the UI and cancellation.
class JobHandle {
  JobHandle(this._api) : id = const Uuid().v4();

  final NativeApi _api;
  final String id;
  final ValueNotifier<double?> progress = ValueNotifier(null);
  final ValueNotifier<String?> message = ValueNotifier(null);
  bool _cancelled = false;
  StreamSubscription<JobProgress>? _sub;

  bool get isCancelled => _cancelled;

  void _listen() {
    _sub = _api.progress.listen((p) {
      if (p.jobId != id) return;
      progress.value = p.fraction;
      if (p.message != null) message.value = p.message;
    }, onError: (_) {});
  }

  /// Progress of Dart-side multi-step work (e.g. batches).
  void report(int done, int total, [String? text]) {
    progress.value = total > 0 ? done / total : null;
    if (text != null) message.value = text;
  }

  Future<void> cancel() async {
    _cancelled = true;
    message.value = 'Cancelling…';
    try {
      await _api.cancel(id);
    } catch (_) {
      // The job may already have finished.
    }
  }

  /// Throws a cancellation error if the user cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw NativeError(NativeError.cancelled, 'Cancelled.');
  }

  void dispose() {
    _sub?.cancel();
    progress.dispose();
    message.dispose();
  }

  static Future<T> run<T>(
    NativeApi api,
    Future<T> Function(JobHandle job) body, {
    void Function(JobHandle job)? onStart,
  }) async {
    final job = JobHandle(api).._listen();
    onStart?.call(job);
    try {
      return await body(job);
    } finally {
      job.dispose();
    }
  }
}
