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
class TidalStreamProxy {
  TidalStreamProxy._();

  static final TidalStreamProxy instance = TidalStreamProxy._();

  HttpServer? _server;
  final Map<String, TidalStreamSession> _sessions = {};
  final Random _rand = Random.secure();

  /// Port of the active loopback server, or null if not yet bound.
  int? get port => _server?.port;

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
  }) async {
    final serverPort = await ensureServer();

    // Reuse existing session for the same track if already active and not cancelled
    final existingSession = _sessions.values.where((s) => s.trackId == trackId && !s.isCancelled).firstOrNull;
    if (existingSession != null) {
      return 'http://127.0.0.1:$serverPort/tidal/${existingSession.streamToken}.mp4';
    }

    // Cancel any previous dead/stale session for the same track
    final deadSession = _sessions.values.where((s) => s.trackId == trackId).firstOrNull;
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

  /// Cancel all active stream sessions and background downloads.
  void cancelAllSessions() {
    for (final session in _sessions.values) {
      session.cancel();
    }
    _sessions.clear();
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
      if (segments.length != 2 || segments[0] != 'tidal') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final filename = segments[1];
      final token = filename.replaceAll('.mp4', '');
      final session = _sessions[token];

      if (session == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      await session.handleRequest(req);
    } catch (e, st) {
      devLog('[TidalStreamProxy] Error handling request: $e\n$st');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
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
  });

  final String streamToken;
  final String trackId;
  final DashTrackInfo dashInfo;
  final String targetPath;
  final http.Client client;

  int _nextSegmentIndex = 1;
  int _lastRequestedSegment = 0;
  bool _pumpRunning = false;
  Completer<void>? _needMoreCompleter;
  final List<int> _segmentStartOffsets = [];

  static const int _bufferAheadLimit = 3;

  File? _partFile;
  RandomAccessFile? _writeRaf;
  int _bytesWritten = 0;
  bool _isFinished = false;
  bool _isCancelled = false;

  final Completer<void> _readyCompleter = Completer<void>();
  final List<({int requiredBytes, Completer<void> completer})> _waiters = [];

  bool get isFinished => _isFinished;
  bool get isCancelled => _isCancelled;
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
    if (_pumpRunning || _isFinished || _isCancelled) return;
    _pumpRunning = true;

    try {
      while (!_isCancelled && !_isFinished && _nextSegmentIndex < dashInfo.segmentUrls.length) {
        // Sliding window: only fetch up to _bufferAheadLimit segments ahead of playback
        if (_nextSegmentIndex > _lastRequestedSegment + _bufferAheadLimit) {
          _needMoreCompleter = Completer<void>();
          await _needMoreCompleter!.future;
          if (_isCancelled || _isFinished) break;
        }

        final myIndex = _nextSegmentIndex;
        final myUrl = dashInfo.segmentUrls[myIndex];

        final resp = await client
            .get(Uri.parse(myUrl))
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) {
          devLog('[TidalStreamProxy] Segment $myIndex fetch failed HTTP ${resp.statusCode}');
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

      if (!_isCancelled && _nextSegmentIndex >= dashInfo.segmentUrls.length) {
        await _finalizeDownload();
      }
    } catch (e) {
      devLog('[TidalStreamProxy] Stream pump error: $e');
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
    if (_isFinished || _isCancelled) return;
    _isFinished = true;
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
      }
    } catch (e) {
      devLog('[TidalStreamSession] Finalize error: $e');
    } finally {
      _notifyWaiters();
    }
  }

  void _notifyWaiters() {
    final current = _bytesWritten;
    _waiters.removeWhere((w) {
      if (_isCancelled || _isFinished || current >= w.requiredBytes) {
        if (!w.completer.isCompleted) {
          w.completer.complete();
        }
        return true;
      }
      return false;
    });
  }

  Future<void> _waitForBytes(int requiredBytes) {
    if (_bytesWritten >= requiredBytes || _isFinished || _isCancelled) {
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add((requiredBytes: requiredBytes, completer: completer));
    return completer.future.timeout(
      const Duration(seconds: 3),
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
    if (_bytesWritten <= start && !_isFinished && !_isCancelled) {
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
    }

    final actualEnd = min(requestedEnd, _bytesWritten - 1);
    final lengthToRead = actualEnd - start + 1;

    if (lengthToRead <= 0) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await req.response.close();
      return;
    }

    // Read byte slice from disk (.part or finished file)
    final filePath = _isFinished ? targetPath : '$targetPath.part';
    final readRaf = await File(filePath).open(mode: FileMode.read);
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
    req.response.headers.set(HttpHeaders.contentLengthHeader, '${chunk.length}');
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
  }
}
