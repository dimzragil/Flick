import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../core/utils/dev_log.dart';
import 'dash_manifest_parser.dart';

/// Local HTTP loopback streaming proxy for Tidal DASH fragmented MP4 (fMP4).
///
/// Instead of waiting for 100% of an 80-150MB Hi-Res track to download before
/// playback starts, this proxy downloads the tiny initialization segment (~2 KB)
/// and the first audio chunk (~800 KB) in ~300ms, and begins serving a local HTTP
/// stream to [RustAudioEngine] immediately.
///
/// Remaining media segments are fetched by a background worker pool and stitched
/// sequentially to the cache file on disk, preserving bit-perfect FLAC audio
/// quality with near-zero latency.
/// Lightweight descriptor for a finalized track whose complete audio file is on disk.
/// Holds minimal metadata (no segment lists or network clients) so loopback Range
/// requests can continue to be served to ExoPlayer / Rust without keeping heavy sessions alive.
class CompletedStream {
  CompletedStream({
    required this.trackId,
    required this.targetPath,
    required this.contentType,
  });

  final String trackId;
  final String targetPath;
  final String contentType;
  String get extension => targetPath.split('.').last;
}

class TidalStreamProxy {
  TidalStreamProxy._();

  static final TidalStreamProxy instance = TidalStreamProxy._();

  static const int _maxCompletedStreams = 4;
  HttpServer? _server;
  final Map<String, TidalStreamSession> _sessions = {};
  final Map<String, TidalBtsStreamSession> _btsSessions = {};
  final Map<String, CompletedStream> _completedFiles = {};
  final Random _rand = Random.secure();

  /// Port of the active loopback server, or null if not yet bound.
  int? get port => _server?.port;

  int get activeSessionCount => _sessions.length;
  int get activeBtsSessionCount => _btsSessions.length;
  int get completedStreamCount => _completedFiles.length;
  bool hasActiveSession(String token) => _sessions.containsKey(token);
  bool hasActiveBtsSession(String token) => _btsSessions.containsKey(token);
  bool hasCompletedStream(String token) => _completedFiles.containsKey(token);

  void _onSessionFinalized(TidalStreamSession session) {
    _sessions.remove(session.streamToken);
    _completedFiles[session.streamToken] = CompletedStream(
      trackId: session.trackId,
      targetPath: session.targetPath,
      contentType: 'audio/mp4',
    );
    if (_completedFiles.length > _maxCompletedStreams) {
      _completedFiles.remove(_completedFiles.keys.first);
    }
  }

  void _onBtsSessionFinalized(TidalBtsStreamSession session) {
    _btsSessions.remove(session.streamToken);
    _completedFiles[session.streamToken] = CompletedStream(
      trackId: session.trackId,
      targetPath: session.targetPath,
      contentType: session.contentType,
    );
    if (_completedFiles.length > _maxCompletedStreams) {
      _completedFiles.remove(_completedFiles.keys.first);
    }
  }

  /// Local URL for an in-progress or finished BTS session; never exposes the CDN URL.
  String? activeBtsStreamUrl(String trackId) {
    final session = _btsSessions.values
        .where((s) => s.trackId == trackId && !s.isCancelled && !s.hasFailed)
        .firstOrNull;
    final serverPort = _server?.port;
    if (serverPort == null) return null;
    if (session != null) {
      return 'http://127.0.0.1:$serverPort/tidal-bts/${session.streamToken}.${session.extension}';
    }
    final completed = _completedFiles.entries
        .where((e) => e.value.trackId == trackId)
        .firstOrNull;
    if (completed != null && File(completed.value.targetPath).existsSync()) {
      return 'http://127.0.0.1:$serverPort/tidal-bts/${completed.key}.${completed.value.extension}';
    }
    return null;
  }

  /// Ensure the loopback server is running and return its port.
  Future<int> ensureServer() async {
    if (_server != null) return _server!.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      _handleRequest,
      onError: (Object e) => devLog('[TidalStreamProxy] Server error: $e'),
    );
    devLog('[TidalStreamProxy] Bound loopback server on port ${server.port}');
    return server.port;
  }

  /// Create a streaming session for a DASH track and wait only for the first
  /// chunk (init + segment 0) to be ready (~300ms).
  ///
  /// Returns the local stream URL (e.g. `http://127.0.0.1:<port>/tidal/<token>.mp4`).
  Future<String> prepareStream({
    required String trackId,
    required DashTrackInfo dashInfo,
    required String targetPath,
    http.Client? client,
    Future<void> Function(File targetFile)? onFinalized,
    Duration? initialRetryDelay,
  }) async {
    final serverPort = await ensureServer();

    // Reuse existing session for the same track if already active, not cancelled, and not failed
    final existingSession = _sessions.values
        .where((s) => s.trackId == trackId && !s.isCancelled && !s.hasFailed)
        .firstOrNull;
    if (existingSession != null) {
      return 'http://127.0.0.1:$serverPort/tidal/${existingSession.streamToken}.mp4';
    }

    final existingCompleted = _completedFiles.entries
        .where((e) => e.value.trackId == trackId)
        .firstOrNull;
    if (existingCompleted != null &&
        File(existingCompleted.value.targetPath).existsSync()) {
      return 'http://127.0.0.1:$serverPort/tidal/${existingCompleted.key}.mp4';
    }

    // Cancel any previous dead/stale session for the same track
    final deadSession = _sessions.values
        .where((s) => s.trackId == trackId)
        .firstOrNull;
    if (deadSession != null) {
      deadSession.cancel();
      _sessions.remove(deadSession.streamToken);
    }

    final token = _generateToken();
    final session = TidalStreamSession(
      streamToken: token,
      trackId: trackId,
      dashInfo: dashInfo,
      targetPath: targetPath,
      client: client ?? http.Client(),
      onFinalized: onFinalized,
      onSessionFinalized: _onSessionFinalized,
      initialRetryDelay: initialRetryDelay ?? const Duration(milliseconds: 500),
    );

    _sessions[token] = session;

    try {
      await session.start();
      return 'http://127.0.0.1:$serverPort/tidal/$token.mp4';
    } catch (e) {
      session.cancel();
      _sessions.remove(token);
      rethrow;
    }
  }

  /// Prebuffer a direct BTS asset locally, then continue writing it in background.
  Future<String> prepareBtsStream({
    required String trackId,
    required String sourceUrl,
    required String targetPath,
    required String contentType,
    http.Client? client,
    Future<void> Function(File targetFile)? onFinalized,
  }) async {
    final serverPort = await ensureServer();
    final existing = _btsSessions.values
        .where((s) => s.trackId == trackId && !s.isCancelled && !s.hasFailed)
        .firstOrNull;
    if (existing != null) {
      return 'http://127.0.0.1:$serverPort/tidal-bts/${existing.streamToken}.${existing.extension}';
    }
    final existingCompleted = _completedFiles.entries
        .where((e) => e.value.trackId == trackId)
        .firstOrNull;
    if (existingCompleted != null &&
        File(existingCompleted.value.targetPath).existsSync()) {
      return 'http://127.0.0.1:$serverPort/tidal-bts/${existingCompleted.key}.${existingCompleted.value.extension}';
    }
    cancelTrack(trackId);
    final token = _generateToken();
    final session = TidalBtsStreamSession(
      streamToken: token,
      trackId: trackId,
      sourceUrl: sourceUrl,
      targetPath: targetPath,
      client: client ?? http.Client(),
      contentType: contentType,
      onFinalized: onFinalized,
      onSessionFinalized: _onBtsSessionFinalized,
    );
    _btsSessions[token] = session;
    try {
      await session.start();
      return 'http://127.0.0.1:$serverPort/tidal-bts/$token.${session.extension}';
    } catch (_) {
      session.cancel();
      _btsSessions.remove(token);
      rethrow;
    }
  }

  /// Cancel all active stream sessions and background downloads.
  void cancelAllSessions() {
    for (final session in _sessions.values) {
      session.cancel();
    }
    for (final session in _btsSessions.values) {
      session.cancel();
    }
    _sessions.clear();
    _btsSessions.clear();
    _completedFiles.clear();
  }

  /// Cancel a session for a specific track.
  void cancelTrack(String trackId) {
    final toRemove = <String>[];
    for (final entry in _sessions.entries) {
      if (entry.value.trackId == trackId) {
        entry.value.cancel();
        toRemove.add(entry.key);
      }
    }
    for (final token in toRemove) {
      _sessions.remove(token);
    }
    _btsSessions.removeWhere((_, session) {
      if (session.trackId != trackId) return false;
      session.cancel();
      return true;
    });
    _completedFiles.removeWhere((_, completed) => completed.trackId == trackId);
  }

  /// Stop the server and clean up all sessions.
  Future<void> stop() async {
    cancelAllSessions();
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  String _generateToken() {
    final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final segments = req.uri.pathSegments;
      if (segments.length == 2 && segments[0] == 'tidal-bts') {
        final filename = segments[1];
        final token = filename.substring(0, filename.lastIndexOf('.'));
        final btsSession = _btsSessions[token];
        if (btsSession != null) {
          await btsSession.handleRequest(req);
          return;
        }
        final completed = _completedFiles[token];
        if (completed != null) {
          await _serveCompletedFile(req, completed);
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (segments.length != 2 || segments[0] != 'tidal') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final filename = segments[1];
      final token = filename.replaceAll('.mp4', '');
      final session = _sessions[token];
      if (session != null) {
        await session.handleRequest(req);
        return;
      }
      final completed = _completedFiles[token];
      if (completed != null) {
        await _serveCompletedFile(req, completed);
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (e, st) {
      devLog('[TidalStreamProxy] Error handling request: $e\n$st');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveCompletedFile(
    HttpRequest req,
    CompletedStream completed,
  ) async {
    final file = File(completed.targetPath);
    if (!await file.exists()) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final fileLength = await file.length();
    final match = RegExp(
      r'bytes=(\d+)-(\d*)',
    ).firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = int.tryParse(match?.group(1) ?? '') ?? 0;
    final requestedEnd =
        int.tryParse(match?.group(2) ?? '') ?? (start + 1024 * 1024 - 1);

    const maxBlockSize = 1024 * 1024;
    var end = requestedEnd;
    if (end - start >= maxBlockSize) {
      end = start + maxBlockSize - 1;
    }

    if (start >= fileLength) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$fileLength',
      );
      await req.response.close();
      return;
    }

    final isBts = req.uri.pathSegments.isNotEmpty &&
        req.uri.pathSegments[0] == 'tidal-bts';
    final actualEnd = (isBts && start == 0)
        ? min(end, min(fileLength - 1, 256 * 1024 - 1))
        : min(end, fileLength - 1);
    final lengthToRead = actualEnd - start + 1;

    if (lengthToRead <= 0) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$fileLength',
      );
      await req.response.close();
      return;
    }

    final raf = await file.open(mode: FileMode.read);
    final List<int> chunk;
    try {
      await raf.setPosition(start);
      chunk = await raf.read(lengthToRead);
    } finally {
      await raf.close();
    }

    if (chunk.isEmpty) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$fileLength',
      );
      await req.response.close();
      return;
    }

    final effectiveEnd = start + chunk.length - 1;
    req.response.statusCode = HttpStatus.partialContent;
    req.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, completed.contentType)
      ..set(HttpHeaders.contentLengthHeader, '${chunk.length}')
      ..set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$effectiveEnd/$fileLength',
      );
    req.response.add(chunk);
    await req.response.close();
  }
}

/// A streaming session representing an active Tidal DASH track.
class TidalStreamSession {
  TidalStreamSession({
    required this.streamToken,
    required this.trackId,
    required this.dashInfo,
    required this.targetPath,
    required this.client,
    this.onFinalized,
    this.onSessionFinalized,
    this.initialRetryDelay = const Duration(milliseconds: 500),
  });

  final String streamToken;
  final String trackId;
  final DashTrackInfo dashInfo;
  final String targetPath;
  final http.Client client;
  final Future<void> Function(File targetFile)? onFinalized;
  final void Function(TidalStreamSession session)? onSessionFinalized;
  final Duration initialRetryDelay;

  int _nextSegmentIndex = 1;
  int _lastRequestedSegment = 0;
  bool _pumpRunning = false;
  bool _pumpFailed = false;
  Completer<void>? _needMoreCompleter;
  final List<int> _segmentStartOffsets = [];

  static const int _bufferAheadLimit = 3;

  File? _partFile;
  RandomAccessFile? _writeRaf;
  int _bytesWritten = 0;
  bool _isFinished = false;
  bool _isCancelled = false;
  bool _isFinalizing = false;
  final Completer<void> _finalizingFile = Completer<void>();

  final Completer<void> _readyCompleter = Completer<void>();
  final List<({int requiredBytes, Completer<void> completer})> _waiters = [];

  bool get isFinished => _isFinished;
  bool get isCancelled => _isCancelled;
  bool get hasFailed => _pumpFailed;
  bool get isHealthy => !_isCancelled && !_pumpFailed;
  int get bytesWritten => _bytesWritten;

  /// Start the session: downloads init + segment 0 and unblocks playback (~300ms).
  Future<void> start() async {
    _partFile = File('$targetPath.part');
    if (await _partFile!.exists()) {
      try {
        await _partFile!.delete();
      } catch (_) {}
    }

    _writeRaf = await _partFile!.open(mode: FileMode.write);
    _segmentStartOffsets.add(0);

    // 1 & 2. Download initialization segment (~2 KB) and segment 0 (~800 KB) in parallel
    final initFuture = client
        .get(Uri.parse(dashInfo.initializationUrl))
        .timeout(const Duration(seconds: 15));
    final seg0Future = dashInfo.segmentUrls.isNotEmpty
        ? client
              .get(Uri.parse(dashInfo.segmentUrls[0]))
              .timeout(const Duration(seconds: 15))
        : null;
    // Attach error listener immediately to prevent orphaned unhandled async errors
    // if initFuture fails or throws before seg0Future is awaited.
    seg0Future?.ignore();

    final initResp = await initFuture;
    if (initResp.statusCode != 200) {
      throw HttpException(
        'Failed to download DASH init segment: HTTP ${initResp.statusCode}',
      );
    }
    if (_isCancelled) throw StateError('Stream cancelled');

    await _writeRaf!.writeFrom(initResp.bodyBytes);
    _bytesWritten += initResp.bodyBytes.length;

    if (seg0Future != null) {
      final seg0Resp = await seg0Future;
      if (seg0Resp.statusCode != 200) {
        throw HttpException(
          'Failed to download DASH segment 0: HTTP ${seg0Resp.statusCode}',
        );
      }
      if (_isCancelled) throw StateError('Stream cancelled');

      await _writeRaf!.writeFrom(seg0Resp.bodyBytes);
      _bytesWritten += seg0Resp.bodyBytes.length;
      await _writeRaf!.flush();
    }

    _segmentStartOffsets.add(_bytesWritten);
    _readyCompleter.complete();

    // 3. Start progressive on-demand streaming pump (keeps modest buffer ahead of playback)
    if (dashInfo.segmentUrls.length > 1) {
      unawaited(_streamPump());
    } else {
      await _finalizeDownload();
    }
  }

  /// Progressive on-demand streaming pump. Only downloads ahead when needed by playback.
  Future<void> _streamPump() async {
    if (_pumpRunning || _isFinished || _isCancelled || _pumpFailed) return;
    _pumpRunning = true;

    try {
      while (!_isCancelled &&
          !_isFinished &&
          !_pumpFailed &&
          _nextSegmentIndex < dashInfo.segmentUrls.length) {
        // Sliding window: only fetch up to _bufferAheadLimit segments ahead of playback
        if (_nextSegmentIndex > _lastRequestedSegment + _bufferAheadLimit) {
          _needMoreCompleter = Completer<void>();
          await _needMoreCompleter!.future;
          if (_isCancelled || _isFinished || _pumpFailed) break;
        }

        final myIndex = _nextSegmentIndex;
        final myUrl = dashInfo.segmentUrls[myIndex];

        http.Response? resp;
        var retryCount = 0;
        const maxRetries = 3;
        var delay = initialRetryDelay;

        while (retryCount <= maxRetries && !_isCancelled) {
          try {
            resp = await client
                .get(Uri.parse(myUrl))
                .timeout(const Duration(seconds: 20));
            if (resp.statusCode == 200) {
              break;
            }
            devLog(
              '[TidalStreamProxy] Segment $myIndex fetch attempt $retryCount failed HTTP ${resp.statusCode}',
            );
          } catch (e) {
            devLog(
              '[TidalStreamProxy] Segment $myIndex fetch attempt $retryCount error: $e',
            );
          }

          retryCount++;
          if (retryCount <= maxRetries && !_isCancelled) {
            if (delay > Duration.zero) {
              await Future<void>.delayed(delay);
            }
            delay *= 2;
          }
        }

        if (resp == null || resp.statusCode != 200) {
          devLog(
            '[TidalStreamProxy] Segment $myIndex fetch failed permanently after $retryCount attempts',
          );
          _pumpFailed = true;
          _notifyWaiters();
          try {
            client.close();
          } catch (_) {}
          break;
        }
        if (_isCancelled) break;

        if (_writeRaf != null && !_isCancelled) {
          await _writeRaf!.writeFrom(resp.bodyBytes);
          await _writeRaf!.flush();
          _bytesWritten += resp.bodyBytes.length;
          _segmentStartOffsets.add(_bytesWritten);
          _notifyWaiters();
        }

        _nextSegmentIndex++;
      }

      if (!_isCancelled &&
          !_pumpFailed &&
          _nextSegmentIndex >= dashInfo.segmentUrls.length) {
        await _finalizeDownload();
      }
    } catch (e) {
      devLog('[TidalStreamProxy] Stream pump error: $e');
      _pumpFailed = true;
      _notifyWaiters();
      try {
        client.close();
      } catch (_) {}
    } finally {
      _pumpRunning = false;
    }
  }

  void _wakePumpForByte(int byteOffset) {
    var seg = 0;
    for (var i = 0; i < _segmentStartOffsets.length - 1; i++) {
      if (byteOffset >= _segmentStartOffsets[i]) {
        seg = i;
      } else {
        break;
      }
    }
    if (byteOffset >= _bytesWritten) {
      seg = _segmentStartOffsets.length - 1;
    }
    if (seg > _lastRequestedSegment) {
      _lastRequestedSegment = seg;
    }
    if (_needMoreCompleter != null && !_needMoreCompleter!.isCompleted) {
      _needMoreCompleter!.complete();
    }
  }

  Future<void> _finalizeDownload() async {
    if (_isFinished || _isCancelled || _isFinalizing) return;
    _isFinalizing = true;
    try {
      await _writeRaf?.flush();
      await _writeRaf?.close();
      _writeRaf = null;

      final target = File(targetPath);
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      if (_partFile != null && await _partFile!.exists()) {
        await _partFile!.rename(targetPath);
        _isFinished = true;
        _isFinalizing = false;
        if (!_finalizingFile.isCompleted) _finalizingFile.complete();
        try {
          client.close();
        } catch (_) {}
        if (onFinalized != null) {
          unawaited(
            Future.microtask(() async {
              try {
                await onFinalized!(File(targetPath));
              } catch (e) {
                devLog('[TidalStreamSession] onFinalized error: $e');
              }
            }),
          );
        }
        onSessionFinalized?.call(this);
      }
    } catch (e) {
      devLog('[TidalStreamSession] Finalize error: $e');
    } finally {
      _isFinalizing = false;
      if (!_finalizingFile.isCompleted) _finalizingFile.complete();
      _notifyWaiters();
    }
  }

  void _notifyWaiters() {
    final current = _bytesWritten;
    _waiters.removeWhere((w) {
      if (_isCancelled ||
          _isFinished ||
          _pumpFailed ||
          current >= w.requiredBytes) {
        if (!w.completer.isCompleted) {
          w.completer.complete();
        }
        return true;
      }
      return false;
    });
  }

  Future<void> _waitForBytes(int requiredBytes) {
    if (_bytesWritten >= requiredBytes ||
        _isFinished ||
        _isCancelled ||
        _pumpFailed) {
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add((requiredBytes: requiredBytes, completer: completer));
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
  }

  /// Handle an incoming HTTP Range request from RustAudioEngine or ExoPlayer.
  Future<void> handleRequest(HttpRequest req) async {
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

    var start = 0;
    int? end;

    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        if (match.group(1)?.isNotEmpty == true) {
          start = int.parse(match.group(1)!);
        }
        if (match.group(2)?.isNotEmpty == true) {
          end = int.parse(match.group(2)!);
        }
      }
    }

    _wakePumpForByte(start);

    // Limit block chunk size to 1 MiB (matches BLOCK_SIZE in Rust HttpMediaSource)
    const maxBlockSize = 1024 * 1024;
    var requestedEnd = end ?? (start + maxBlockSize - 1);
    if (requestedEnd - start >= maxBlockSize) {
      requestedEnd = start + maxBlockSize - 1;
    }

    // Wait until at least start + 1 bytes are written
    if (_bytesWritten <= start &&
        !_isFinished &&
        !_isCancelled &&
        !_pumpFailed) {
      await _waitForBytes(start + 1);
    }

    if (start >= _bytesWritten) {
      if (_isFinished) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$_bytesWritten',
        );
        await req.response.close();
        return;
      }
      // Offset not yet downloaded, but download is not finished:
      // If pump failed or request timed out, return 503 (NEVER 416).
      // Rust treats 416 as EOF, which would prematurely terminate playback.
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await req.response.close();
      return;
    }

    final actualEnd = min(requestedEnd, _bytesWritten - 1);
    final lengthToRead = actualEnd - start + 1;

    if (lengthToRead <= 0) {
      if (_isFinished) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$_bytesWritten',
        );
      } else {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      }
      await req.response.close();
      return;
    }

    if (_isFinalizing) await _finalizingFile.future;

    // Read byte slice from disk (.part or finished file)
    final filePath = _isFinished ? targetPath : '$targetPath.part';
    RandomAccessFile readRaf;
    try {
      readRaf = await File(filePath).open(mode: FileMode.read);
    } on FileSystemException {
      // Finalization may rename the part file between checking and opening it.
      readRaf = await File(targetPath).open(mode: FileMode.read);
    }
    final List<int> chunk;
    try {
      await readRaf.setPosition(start);
      chunk = await readRaf.read(lengthToRead);
    } finally {
      await readRaf.close();
    }

    final totalStr = _isFinished ? '$_bytesWritten' : '*';

    req.response.statusCode = HttpStatus.partialContent;
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mp4');
    req.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$actualEnd/$totalStr',
    );
    req.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${chunk.length}',
    );
    req.response.add(chunk);
    await req.response.close();
  }

  /// Cancel the session, stop workers, and close file handles.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _notifyWaiters();
    if (_needMoreCompleter != null && !_needMoreCompleter!.isCompleted) {
      _needMoreCompleter!.complete();
    }

    try {
      _writeRaf?.close();
    } catch (_) {}
    _writeRaf = null;

    if (!_isFinished && _partFile != null) {
      try {
        _partFile!.deleteSync();
      } catch (_) {}
    }
    try {
      client.close();
    } catch (_) {}
  }
}

/// Progressive local file proxy for a single, unsegmented BTS asset.
class TidalBtsStreamSession {
  static const int _initialBufferBytes = 256 * 1024;

  /// Tail prefetch size. Format probes (symphonia) seek to the last ~64KB of
  /// the file; prefetching the tail in parallel means those seeks are served
  /// instantly instead of stalling until the sequential download catches up
  /// (measured 2.8-5.2s stall on every TIDAL CD cold start).
  static const int _tailPrefetchBytes = 256 * 1024;
  TidalBtsStreamSession({
    required this.streamToken,
    required this.trackId,
    required this.sourceUrl,
    required this.targetPath,
    required this.client,
    required this.contentType,
    this.onFinalized,
    this.onSessionFinalized,
  });
  final String streamToken, trackId, sourceUrl, targetPath, contentType;
  final http.Client client;
  final Future<void> Function(File targetFile)? onFinalized;
  final void Function(TidalBtsStreamSession session)? onSessionFinalized;
  String get extension => targetPath.split('.').last;
  bool _cancelled = false, _finished = false;
  bool _failed = false;
  bool get isCancelled => _cancelled;
  bool get isFinished => _finished;
  bool get hasFailed => _failed;
  bool get isHealthy => !_cancelled && !_failed;
  int _written = 0;
  int? _total;

  /// Start offset of the prefetched tail region, once fully written to disk.
  /// Null until the parallel tail download completes.
  int? _tailReadyStart;
  RandomAccessFile? _writer;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _finalizingFile = Completer<void>();
  final List<({int requiredBytes, Completer<void> completer})> _waiters = [];
  bool _isFinalizing = false;

  void _notifyWaiters() {
    final current = _written;
    _waiters.removeWhere((w) {
      if (_cancelled || _finished || _failed || current >= w.requiredBytes) {
        if (!w.completer.isCompleted) {
          w.completer.complete();
        }
        return true;
      }
      return false;
    });
  }

  Future<void> _waitForBytes(int requiredBytes) {
    if (_written >= requiredBytes || _finished || _cancelled || _failed) {
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add((requiredBytes: requiredBytes, completer: completer));
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
  }

  Future<void> start() async {
    final part = File('$targetPath.part');
    if (await part.exists()) {
      await part.delete();
    }
    _writer = await part.open(mode: FileMode.write);
    // Fire the tail prefetch FIRST, in parallel with the main request below.
    // A suffix range needs no prior knowledge of the total size, so both
    // requests pay TTFB concurrently instead of sequentially.
    final tailFuture = _prefetchTail(part);
    final request = http.Request('GET', Uri.parse(sourceUrl));
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      _failed = true;
      _notifyWaiters();
      try {
        client.close();
      } catch (_) {}
      throw HttpException('BTS CDN returned HTTP ${response.statusCode}');
    }
    _total = response.contentLength;
    unawaited(_consume(response.stream, part));
    // Wait for BOTH the head prebuffer and the tail prefetch. They download
    // in parallel, so the slower one dominates (~0ms added in practice), and
    // the probe's tail seek can never race the prefetch again.
    await _ready.future.timeout(const Duration(seconds: 20));
    try {
      await tailFuture.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Tail prefetch too slow; proceed without it. Tail-region requests
      // fall back to waiting for the sequential download (old behavior).
    }
  }

  /// Download the last [_tailPrefetchBytes] of the source file straight to
  /// its final offset in the part file, in parallel with the sequential head
  /// download. Uses a suffix range so it can start before the total size is
  /// known. Format probes seek to the tail (symphonia reads the final ~64KB);
  /// without this, [handleRequest] would block such seeks until the
  /// sequential download catches up — seconds of stall on every cold start.
  /// Best-effort: on any failure the tail simply isn't marked ready and
  /// requests fall back to waiting for the sequential download.
  Future<void> _prefetchTail(File part) async {
    try {
      final tailRequest = http.Request('GET', Uri.parse(sourceUrl));
      tailRequest.headers['Range'] = 'bytes=-$_tailPrefetchBytes';
      final tailResponse = await client
          .send(tailRequest)
          .timeout(const Duration(seconds: 20));
      // Only a 206 partial response is usable: a 200 would mean the server
      // ignored the suffix range, and writing the full body at a tail offset
      // would corrupt the file.
      if (tailResponse.statusCode != 206) {
        await tailResponse.stream.drain<void>();
        return;
      }
      // "bytes 9986453-10248596/10248597" -> tailStart=9986453.
      final contentRange = tailResponse.headers['content-range'];
      final match = RegExp(
        r'bytes (\d+)-\d+/(\d+)',
      ).firstMatch(contentRange ?? '');
      if (match == null) {
        await tailResponse.stream.drain<void>();
        return;
      }
      final tailStart = int.parse(match.group(1)!);
      _total ??= int.parse(match.group(2)!);
      if (tailStart == 0) {
        // File fits in the tail window; the head download covers it all.
        await tailResponse.stream.drain<void>();
        return;
      }
      // append mode (not write) so the in-progress head download is preserved;
      // setPosition moves the cursor to the tail offset.
      final tailWriter = await part.open(mode: FileMode.append);
      try {
        await tailWriter.setPosition(tailStart);
        await for (final chunk in tailResponse.stream) {
          if (_cancelled) break;
          await tailWriter.writeFrom(chunk);
        }
        await tailWriter.flush();
      } finally {
        await tailWriter.close();
      }
      if (!_cancelled) {
        _tailReadyStart = tailStart;
      }
    } catch (_) {
      // Best-effort; the sequential download still works without the tail.
    }
  }

  Future<void> _consume(Stream<List<int>> stream, File part) async {
    try {
      await for (final bytes in stream) {
        if (_cancelled) break;
        if (_writer != null) {
          await _writer!.writeFrom(bytes);
          await _writer!.flush();
          _written += bytes.length;
          _notifyWaiters();
        }
        if (!_ready.isCompleted &&
            (_written >= _initialBufferBytes ||
                (_total != null && _written >= _total!))) {
          _ready.complete();
        }
      }
      if (!_cancelled) {
        await _writer?.flush();
        await _writer?.close();
        _writer = null;
        final target = File(targetPath);
        if (await target.exists()) await target.delete();
        _isFinalizing = true;
        await part.rename(targetPath);
        _finished = true;
        _isFinalizing = false;
        if (!_finalizingFile.isCompleted) _finalizingFile.complete();
        try {
          client.close();
        } catch (_) {}
        if (onFinalized != null) unawaited(onFinalized!(File(targetPath)));
        if (!_ready.isCompleted) _ready.complete();
        _notifyWaiters();
        onSessionFinalized?.call(this);
      } else {
        // Cancelled before the prebuffer completed: fail _ready so start()
        // unblocks immediately instead of hanging out the 20s timeout.
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('BTS session cancelled'));
        }
      }
    } catch (e) {
      _failed = true;
      _finished = true;
      _isFinalizing = false;
      try {
        client.close();
      } catch (_) {}
      if (!_finalizingFile.isCompleted) _finalizingFile.complete();
      if (!_ready.isCompleted) _ready.completeError(e);
      devLog('[TidalStreamProxy] BTS download failed: $e');
      _notifyWaiters();
    }
  }

  Future<void> handleRequest(HttpRequest req) async {
    final match = RegExp(
      r'bytes=(\d+)-(\d*)',
    ).firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = int.tryParse(match?.group(1) ?? '') ?? 0;
    final requestedEnd =
        int.tryParse(match?.group(2) ?? '') ?? (start + 1024 * 1024 - 1);

    // Limit block chunk size to 1 MiB (matches BLOCK_SIZE in Rust HttpMediaSource)
    const maxBlockSize = 1024 * 1024;
    var end = requestedEnd;
    if (end - start >= maxBlockSize) {
      end = start + maxBlockSize - 1;
    }

    final initialRequest = start == 0;

    // Tail region prefetched in parallel: serve immediately without waiting
    // for the sequential download to catch up (format probes seek here).
    final tailStart = _tailReadyStart;
    final servesTail = tailStart != null && start >= tailStart;

    // For the initial probe request, wait until _initialBufferBytes are ready.
    // For subsequent streaming requests, only wait until the requested `start` offset has data.
    final minRequired = initialRequest ? _initialBufferBytes : (start + 1);
    if (!servesTail &&
        _written < minRequired &&
        !_finished &&
        !_cancelled &&
        !_failed) {
      await _waitForBytes(minRequired);
    }

    if (start >= _written && !servesTail) {
      if (_finished && !_failed) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        if (_total != null) {
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$_total',
          );
        }
        await req.response.close();
        return;
      }
      // Offset not yet downloaded, or download failed:
      // Return 503 (NEVER 416). Rust treats 416 as EOF.
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await req.response.close();
      return;
    }

    if (_isFinalizing) await _finalizingFile.future;
    // The prefetched tail is fully present on disk even though the sequential
    // head download hasn't reached it yet.
    final available = servesTail
        ? (_total ?? _written)
        : (_total == null ? _written : min(_written, _total!));

    // Probe request is capped to _initialBufferBytes to minimize startup latency.
    // Subsequent streaming requests return whatever bytes are currently buffered.
    final actualEnd = initialRequest
        ? min(end, min(available - 1, _initialBufferBytes - 1))
        : min(end, available - 1);
    final lengthToRead = actualEnd - start + 1;

    if (lengthToRead <= 0) {
      if (_finished && !_failed) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        if (_total != null) {
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$_total',
          );
        }
      } else {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      }
      await req.response.close();
      return;
    }

    RandomAccessFile raf;
    try {
      raf = await File(
        _finished ? targetPath : '$targetPath.part',
      ).open(mode: FileMode.read);
    } on FileSystemException {
      // Finalization may rename the part file between checking and opening it.
      raf = await File(targetPath).open(mode: FileMode.read);
    }
    await raf.setPosition(start);
    final bytes = await raf.read(lengthToRead);
    await raf.close();

    if (bytes.isEmpty) {
      if (_finished && !_failed) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      } else {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      }
      await req.response.close();
      return;
    }

    final effectiveEnd = start + bytes.length - 1;
    req.response.statusCode = HttpStatus.partialContent;
    req.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.contentLengthHeader, '${bytes.length}')
      ..set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$effectiveEnd/${_total ?? '*'}',
      );
    req.response.add(bytes);
    await req.response.close();
  }

  void cancel() {
    _cancelled = true;
    try {
      _writer?.close();
    } catch (_) {}
    _writer = null;
    try {
      File('$targetPath.part').deleteSync();
    } catch (_) {}
    try {
      client.close();
    } catch (_) {}
    _notifyWaiters();
  }
}
