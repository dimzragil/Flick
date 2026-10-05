import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/core/utils/dev_log.dart';

typedef ScrobbleBatchSender<T> = Future<void> Function(List<T> entries);
typedef EntrySerializer<T> = Map<String, dynamic> Function(T entry);
typedef EntryDeserializer<T> = T Function(Map<String, dynamic> json);
typedef EntryLogDescription<T> = String Function(T entry);
typedef AuthErrorFilter = bool Function(Object error);

/// Generic offline-safe scrobble queue persisted in SharedPreferences.
class ScrobbleQueue<TEntry> {
  ScrobbleQueue({
    required String logTag,
    required String queueKey,
    required int maxQueueSize,
    required EntrySerializer<TEntry> toJson,
    required EntryDeserializer<TEntry> fromJson,
    required EntryLogDescription<TEntry> describeEntry,
    required ScrobbleBatchSender<TEntry> sendBatch,
    AuthErrorFilter? handleAuthError,
  })  : _logTag = logTag,
        _queueKey = queueKey,
        _maxQueueSize = maxQueueSize,
        _toJson = toJson,
        _fromJson = fromJson,
        _describeEntry = describeEntry,
        _sendBatch = sendBatch,
        _handleAuthError = handleAuthError;

  final String _logTag;
  final String _queueKey;
  final int _maxQueueSize;
  final EntrySerializer<TEntry> _toJson;
  final EntryDeserializer<TEntry> _fromJson;
  final EntryLogDescription<TEntry> _describeEntry;
  final ScrobbleBatchSender<TEntry> _sendBatch;
  final AuthErrorFilter? _handleAuthError;

  Future<void> enqueue(TEntry entry) async {
    final queue = await _load();
    queue.add(_toJson(entry));
    // Drop oldest entries if queue exceeds max size
    if (queue.length > _maxQueueSize) {
      final dropped = queue.length - _maxQueueSize;
      queue.removeRange(0, dropped);
      devLog('$_logTag queue overflow: dropped $dropped oldest entries');
    }
    devLog(
      '$_logTag queue enqueue ${_describeEntry(entry)} pending=${queue.length}',
    );
    await _save(queue);
  }

  /// Attempts to flush all queued scrobbles.
  /// Keeps queue intact on failure for future retries.
  Future<void> flush() async {
    final raw = await _load();
    if (raw.isEmpty) {
      devLog('$_logTag queue flush skipped: empty');
      return;
    }

    devLog('$_logTag queue flush start pending=${raw.length}');

    final entries = raw
        .map(
          (entry) => _fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();

    try {
      await _sendBatch(entries);
      await _clear();
      devLog('$_logTag queue flush success; queue cleared');
    } catch (e) {
      if (_handleAuthError != null && _handleAuthError(e)) {
        return;
      }
      devLog('$_logTag queue flush failed; queue retained');
      rethrow;
    }
  }

  Future<List<dynamic>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null) {
      return [];
    }
    try {
      return jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      // Malformed or incompatible JSON; clear stored queue and start fresh
      devLog('$_logTag queue load failed; clearing corrupt data: $e');
      await prefs.remove(_queueKey);
      return [];
    }
  }

  Future<void> _save(List<dynamic> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(queue));
  }

  Future<void> _clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_queueKey);
  }
}
