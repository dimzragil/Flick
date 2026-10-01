import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/dev_log.dart';
import '../../data/database.dart';
import '../../data/repositories/song_repository.dart';
import '../../models/playback_context.dart';
import '../../models/song.dart';
import '../../models/sources/tidal_models.dart';
import '../library_scanner_service.dart' show ScanProgress;
import '../network_cache_service.dart';
import 'dash_manifest_parser.dart';
import 'network_source_service.dart';
import 'tidal_stream_proxy.dart';

/// Tidal client over the reverse-engineered web/OAuth2 surface.
///
/// Auth is Tidal's OAuth2 **device-authorization grant**: the app impersonates a
/// Tidal web/desktop client using its public `clientId` and the user authorizes
/// on their own device with their own Tidal account. Tokens (access + refresh)
/// are persisted as a JSON blob in [NetworkServerEntity.token] and refreshed
/// transparently on expiry, writing the new token back to the DB.
///
/// Playback: `/tracks/{id}/playbackinfopostpaywall` returns a `vnd.tidal.bts`
/// manifest. For `encryptionType: NONE` (HiFi lossless FLAC/ALAC) the contained
/// CDN url is prebuffered through [TidalStreamProxy] before the engine reads it
/// as a local ranged HTTP source; completed files remain in the network cache.
/// Encrypted manifests (MQA / HiRes Master / Atmos, `encryptionType != NONE` or
/// DASH) are **not** decryptable here and fail with a clear error rather than
/// fake playback — matching the project's "no fake transport" rule. This is the
/// tradeoff of the no-partner-SDK path the user explicitly accepted.
///
/// Tidal rotates the web client credentials; update [clientId]/[clientSecret]
/// if auth starts returning `invalid_client`.
class TidalService implements NetworkSourceService {
  TidalService._({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    Future<bool> Function(Uri)? urlOpener,
  }) : _client = client ?? http.Client(),
       _songRepository = songRepository,
       _networkCache = networkCache,
       _urlOpener = urlOpener ?? _defaultOpenUrl;

  static TidalService instance = TidalService._();

  @visibleForTesting
  static TidalService create({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    Future<bool> Function(Uri)? urlOpener,
  }) => TidalService._(
    client: client,
    songRepository: songRepository,
    networkCache: networkCache,
    urlOpener: urlOpener,
  );

  // ponytail: Tidal desktop/TV app OAuth2 client credentials, scraped from the
  // app and published by the RE community (EbbLabs/python-tidal). NOT an official
  // API key; Tidal rotates these at will. If auth starts returning
  // `invalid_client`, pull a fresh client_id/client_secret pair from the same
  // source.
  static const String clientId = 'fX2JxdmntZWK0ixT';
  static const String clientSecret =
      '1Nn9AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg=';
  static const String _scope = 'r_usr w_usr w_sub';

  static const String _authBase = 'https://auth.tidal.com/v1/oauth2';
  static const String _apiBase = 'https://api.tidal.com/v1';
  static const String _apiV2Base = 'https://api.tidal.com/v2';
  static const String _openapiBase = 'https://openapi.tidal.com/v2';
  static const String _coverMarkerScheme = 'tidal-cover://';
  static const String _coverHost = 'https://resources.tidal.com/images';
  static const String _eventCollectorUrl =
      'https://ec.tidal.com/api/event-batch';

  /// Tidal base url is fixed; baseUrl on the entity is cosmetic only.
  static const String tidalBaseUrl = 'https://tidal.com';

  final http.Client _client;
  SongRepository? _songRepository;
  NetworkCacheService? _networkCache;
  final Future<bool> Function(Uri) _urlOpener;
  final Map<String, TidalStreamResolution> _resolvedStreams = {};
  final Map<String, void Function()> _activeDownloads = {};

  /// Catalog-known max quality tier per TIDAL track id (e.g. 'LOSSLESS').
  ///
  /// Populated from catalog tags in [makeEphemeralSong] (static, so this is
  /// static too). Lets [_resolveStreamable] start its quality-tier cascade
  /// at the right tier instead of wasting `playbackinfo` API calls on
  /// higher tiers the track can never satisfy — CD-only ("Lossless") tracks
  /// otherwise pay two doomed round-trips on every cold start. Tracks
  /// without an entry fall back to the full cascade.
  static final Map<String, String> _tierStartHintByTrackId = {};

  SongRepository get _repo => _songRepository ??= SongRepository();
  NetworkCacheService get _cache => _networkCache ??= NetworkCacheService();

  /// Retrieve cached stream resolution (sampleRate, bitDepth, quality, codec) for a track.
  TidalStreamResolution? getResolvedStream(String trackId) =>
      _resolvedStreams[trackId];

  /// Cancel in-flight download for a specific track.
  void cancelActiveDownload(String remoteId) {
    _activeDownloads[remoteId]?.call();
    _activeDownloads.remove(remoteId);
    TidalStreamProxy.instance.cancelTrack(remoteId);
  }

  /// Cancel all in-flight downloads (e.g. when changing songs immediately).
  void cancelAllDownloads() {
    for (final cancel in _activeDownloads.values.toList()) {
      cancel();
    }
    _activeDownloads.clear();
    TidalStreamProxy.instance.cancelAllSessions();
  }

  static Future<bool> _defaultOpenUrl(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  String get protocol => NetworkProtocol.tidal;

  @override
  String get coverScheme => _coverMarkerScheme;

  _TidalCreds? _creds(String? token) {
    if (token == null || token.isEmpty) return null;
    try {
      final j = jsonDecode(token) as Map<String, dynamic>;
      final access = j['access_token'] as String?;
      if (access == null) return null;
      return _TidalCreds(
        accessToken: access,
        refreshToken: j['refresh_token'] as String?,
        userId: j['user_id'] as String?,
        countryCode: (j['country_code'] as String?) ?? 'US',
        expiresAtMs: (j['expires_at_ms'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  String _countryCode(String? token) => _creds(token)?.countryCode ?? 'US';

  // --- OAuth2 device-code login ------------------------------------------

  @override
  Future<String?> resolveToken(NetworkServerEntity server, String password) =>
      signIn();

  /// OAuth2 device-code sign-in. The browser is auto-launched best-effort; if
  /// that fails (no browser app / ACTIVITY_NOT_FOUND), [onVerificationLink]
  /// receives the URI so the caller can offer manual copy/open. Polling
  /// continues regardless, so authorization completed on any device finishes
  /// the sign-in. Without a callback, a launch failure fast-fails with the link
  /// carried on the [TidalException].
  Future<String?> signIn({
    void Function(String verificationLink)? onVerificationLink,
  }) async {
    final dev = await _postForm('$_authBase/device_authorization', {
      'client_id': clientId,
      'scope': _scope,
    });
    final deviceCode = dev['deviceCode'] as String?;
    final rawUri =
        (dev['verificationUriComplete'] as String?) ??
        (dev['verificationUri'] as String?);
    // Tidal returns the verification URL scheme-less (link.tidal.com/CODE);
    // url_launcher needs https:// or the VIEW intent matches nothing and
    // throws ACTIVITY_NOT_FOUND.
    final verificationUri = rawUri == null || rawUri.startsWith('http')
        ? rawUri
        : 'https://$rawUri';
    final intervalSec = (dev['interval'] as num?)?.toInt() ?? 5;
    final expiresInSec = (dev['expiresIn'] as num?)?.toInt() ?? 300;
    if (deviceCode == null || verificationUri == null) {
      throw TidalException('Tidal did not return a sign-in code.');
    }
    // Opening the browser can throw (e.g. Android ACTIVITY_NOT_FOUND when no
    // app handles the link). Treat a throw the same as a false return — with a
    // callback the device-code flow still works if the user opens the link on
    // any device; without one we fast-fail carrying the link.
    var launched = false;
    try {
      launched = await _urlOpener(Uri.parse(verificationUri));
    } catch (e) {
      devLog('[Tidal] browser launch failed: $e');
    }
    if (!launched) {
      if (onVerificationLink != null) {
        onVerificationLink(verificationUri);
      } else {
        throw TidalException(
          "Couldn't open the browser automatically. Open this link on any "
          'device to finish signing in, then tap Sign in again:\n\n'
          '$verificationUri',
          verificationUri: verificationUri,
        );
      }
    }

    final deadline = DateTime.now().add(Duration(seconds: expiresInSec));
    var sleep = intervalSec;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: sleep));
      final tok = await _postForm('$_authBase/token', {
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': deviceCode,
        'scope': _scope,
      }, raw: true);

      final access = tok['access_token'] as String?;
      if (access != null) {
        final session = await _fetchSession(access);
        final expiresAt = DateTime.now().add(
          Duration(seconds: (tok['expires_in'] as num?)?.toInt() ?? 3600),
        );
        return jsonEncode({
          'access_token': access,
          'refresh_token': tok['refresh_token'],
          'user_id': session.userId,
          'country_code': session.countryCode,
          'expires_at_ms': expiresAt.millisecondsSinceEpoch,
        });
      }
      switch (tok['error']) {
        case 'expired_token':
          throw TidalException('The Tidal sign-in code expired. Try again.');
        case 'access_denied':
          throw TidalException('Tidal sign-in was denied.');
        case 'slow_down':
          sleep += 5;
          break;
        default:
          break; // authorization_pending — keep polling.
      }
    }
    throw TidalException('Timed out waiting for Tidal sign-in.');
  }

  /// Resolve the user id + country code from the bearer `/sessions` endpoint.
  /// The OAuth token response carries neither, so they must be fetched here.
  Future<({String userId, String countryCode})> _fetchSession(
    String accessToken,
  ) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$_apiBase/sessions'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final j = jsonDecode(response.body) as Map<String, dynamic>;
        final uid = j['userId']?.toString();
        final cc = j['countryCode'] as String?;
        if (uid != null && uid.isNotEmpty) {
          return (
            userId: uid,
            countryCode: (cc != null && cc.isNotEmpty) ? cc : 'US',
          );
        }
      }
    } catch (_) {
      /* fall through to defaults */
    }
    return (userId: '', countryCode: 'US');
  }

  // --- Token lifecycle (refresh + persist) -------------------------------

  Future<_TidalCreds> _ensureValidToken(NetworkServerEntity server) async {
    final creds = _creds(server.token);
    if (creds == null) {
      throw TidalException('No Tidal sign-in. Tap "Sign in with Tidal".');
    }
    final nearExpiry =
        creds.expiresAtMs == null ||
        DateTime.now().millisecondsSinceEpoch > creds.expiresAtMs! - 60000;
    if (nearExpiry && creds.refreshToken != null) {
      return _refresh(server, creds);
    }
    return creds;
  }

  Future<_TidalCreds> _refresh(
    NetworkServerEntity server,
    _TidalCreds old,
  ) async {
    final refresh = old.refreshToken;
    if (refresh == null) {
      throw TidalException('Tidal session expired. Please sign in again.');
    }
    final tok = await _postForm('$_authBase/token', {
      'client_id': clientId,
      if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    final access = tok['access_token'] as String?;
    if (access == null) {
      throw TidalException('Tidal token refresh failed.');
    }
    final updated = _TidalCreds(
      accessToken: access,
      refreshToken: (tok['refresh_token'] as String?) ?? refresh,
      userId: old.userId,
      countryCode: old.countryCode,
      expiresAtMs: DateTime.now()
          .add(Duration(seconds: (tok['expires_in'] as num?)?.toInt() ?? 3600))
          .millisecondsSinceEpoch,
    );
    await _persist(server, updated);
    return updated;
  }

  Future<void> _persist(NetworkServerEntity server, _TidalCreds creds) async {
    final token = jsonEncode({
      'access_token': creds.accessToken,
      'refresh_token': creds.refreshToken,
      'user_id': creds.userId,
      'country_code': creds.countryCode,
      'expires_at_ms': creds.expiresAtMs,
    });
    try {
      await Database.instance.writeTxn(() async {
        final stored = await Database.networkServers.get(server.id);
        if (stored != null) {
          stored.token = token;
          await Database.networkServers.put(stored);
        }
      });
    } catch (e) {
      devLog('Tidal token persist failed: $e');
    }
  }

  // --- JSON API ----------------------------------------------------------

  Future<Map<String, dynamic>> _apiGet(
    NetworkServerEntity server,
    String path, {
    Map<String, String>? query,
    bool retry = true,
  }) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse(
      '$_apiBase$path',
    ).replace(queryParameters: {'countryCode': creds.countryCode, ...?query});
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiGet(server, path, query: query, retry: false);
    }
    if (response.statusCode != 200) {
      throw TidalException('HTTP ${response.statusCode} for $path');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postForm(
    String url,
    Map<String, String> fields, {
    bool raw = false,
  }) async {
    final response = await _client
        .post(Uri.parse(url), body: fields)
        .timeout(const Duration(seconds: 20));
    final body = response.body;
    Map<String, dynamic>? parsed;
    if (body.isNotEmpty) {
      try {
        parsed = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        /* parsed stays null */
      }
    }
    if (response.statusCode != 200 && !raw) {
      // Raw detail only for developers; the user sees a friendly message.
      devLog('[Tidal] POST $url -> HTTP ${response.statusCode}: $body');
      throw TidalException(_friendlyHttp(response.statusCode, parsed));
    }
    return parsed ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _apiV2Get(
    NetworkServerEntity server,
    String path, {
    Map<String, String>? query,
    bool retry = true,
  }) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse('$_apiV2Base$path').replace(
      queryParameters: {
        'countryCode': creds.countryCode,
        'locale': 'en_US',
        'deviceType': 'BROWSER',
        'platform': 'WEB',
        ...?query,
      },
    );
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            'Accept': 'application/json',
            'x-tidal-client-version': '2026.9.15',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiV2Get(server, path, query: query, retry: false);
    }
    if (response.statusCode != 200) {
      throw TidalException('HTTP ${response.statusCode} for $path');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    } else if (decoded is List) {
      return {'items': decoded};
    }
    return <String, dynamic>{};
  }

  Future<http.Response> _apiAuthPostForm(
    NetworkServerEntity server,
    String url,
    Map<String, String> fields, {
    Map<String, String>? headers,
    bool retry = true,
  }) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse(
      url,
    ).replace(queryParameters: {'countryCode': creds.countryCode});
    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            ...?headers,
          },
          body: fields,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiAuthPostForm(
        server,
        url,
        fields,
        headers: headers,
        retry: false,
      );
    }
    return response;
  }

  Future<http.Response> _apiAuthPostJson(
    NetworkServerEntity server,
    String url,
    Map<String, dynamic> body, {
    bool retry = true,
  }) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse(
      url,
    ).replace(queryParameters: {'countryCode': creds.countryCode});
    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiAuthPostJson(server, url, body, retry: false);
    }
    return response;
  }

  Future<http.Response> _apiAuthDelete(
    NetworkServerEntity server,
    String url, {
    bool retry = true,
  }) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse(
      url,
    ).replace(queryParameters: {'countryCode': creds.countryCode});
    final response = await _client
        .delete(uri, headers: {'Authorization': 'Bearer ${creds.accessToken}'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiAuthDelete(server, url, retry: false);
    }
    return response;
  }

  Future<({String? etag, Map<String, dynamic> body})> _getPlaylistWithEtag(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    final creds = await _ensureValidToken(server);
    final uri = Uri.parse(
      '$_apiBase/playlists/$playlistId',
    ).replace(queryParameters: {'countryCode': creds.countryCode});
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer ${creds.accessToken}',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 20));
    final etag = response.headers['etag'];
    Map<String, dynamic> parsed = {};
    if (response.body.isNotEmpty) {
      try {
        parsed = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}
    }
    return (etag: etag, body: parsed);
  }

  /// Map a raw HTTP failure to a short, user-facing message. The raw body is
  /// logged separately via [devLog] (developer mode only).
  static String _friendlyHttp(int status, Map<String, dynamic>? parsed) {
    final err = parsed?['error'] as String?;
    if (err == 'invalid_client') {
      return 'Tidal rejected the app sign-in key. It rotates these — the built-in '
          'key may be out of date (a known limitation of the unofficial path).';
    }
    if (status == 401 || status == 403) {
      return 'Tidal refused the sign-in. Try again.';
    }
    if (status == 429) {
      return 'Too many Tidal requests. Wait a moment and try again.';
    }
    if (status >= 500) {
      return 'Tidal is unavailable right now. Try again shortly.';
    }
    return 'Could not reach Tidal (HTTP $status). Check your connection.';
  }

  // --- ping --------------------------------------------------------------

  @override
  Future<bool> ping(NetworkServerEntity server) async {
    final creds = _creds(server.token);
    if (creds == null || creds.userId == null || creds.userId!.isEmpty) {
      devLog('Tidal ping failed: no stored token');
      return false;
    }
    try {
      await _apiGet(server, '/users/${creds.userId}');
      return true;
    } catch (e) {
      devLog('Tidal ping failed: $e');
      return false;
    }
  }

  // --- Cover art ---------------------------------------------------------

  @override
  Future<List<int>> getCoverArt(
    NetworkServerEntity server,
    String marker,
  ) async {
    final url = coverUrl(marker);
    if (url.isEmpty) {
      throw TidalException('No Tidal cover for $marker');
    }
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw TidalException('HTTP ${response.statusCode} for cover $marker');
    }
    return response.bodyBytes;
  }

  /// Build a `resources.tidal.com` cover URL from a Tidal cover uuid.
  static String coverUrl(String coverUuid, {int size = 1280}) {
    if (coverUuid.isEmpty) return '';
    final clean = coverUuid.replaceAll('-', '');
    if (clean.length < 5) return '';
    // Nil UUID (all zeros e.g. 00000000-0000-0000-0000-000000000000) or non-content placeholder
    if (clean.replaceAll('0', '').isEmpty) return '';
    final String path;
    if (clean.length == 32) {
      path =
          '${clean.substring(0, 8)}/${clean.substring(8, 12)}/${clean.substring(12, 16)}/${clean.substring(16, 20)}/${clean.substring(20)}';
    } else {
      path = coverUuid.replaceAll('-', '/');
    }
    return '$_coverHost/$path/${size}x$size.jpg';
  }

  // --- Stream ----------------------------------------------------------

  @override
  Future<({String url, Map<String, String> headers})?> streamDescriptor(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
  }) async {
    // 1. If already cached locally, return null so playback uses the local file directly.
    try {
      final cached = await _cache.getPath(
        server.id,
        remoteId,
        extension: _resolvedStreams[remoteId]?.ext ?? extension ?? 'mp4',
      );
      if (cached != null) return null;
    } catch (_) {}

    // PlayerService resolves once for display metadata, then Rust resolves
    // again to start playback. Reuse the active localhost session so that
    // second pass does not issue another playback-info API request.
    final activeBtsUrl = TidalStreamProxy.instance.activeBtsStreamUrl(remoteId);
    final activeResolution = _resolvedStreams[remoteId];
    if (activeBtsUrl != null && activeResolution != null) {
      return (
        url: activeBtsUrl,
        headers: <String, String>{
          'x-flick-sample-rate': activeResolution.sampleRate.toString(),
          'x-flick-bit-depth': activeResolution.bitDepth.toString(),
        },
      );
    }

    final resolved = await _resolveStreamable(server, remoteId);
    if (resolved == null) return null;

    // 2. For DASH: start or prepare the progressive local stream session (~300ms)
    if (resolved.isDash && resolved.dashInfo != null) {
      final targetPath = await _cache.pathFor(
        server.id,
        remoteId,
        extension: 'mp4',
      );
      final streamUrl = await TidalStreamProxy.instance.prepareStream(
        trackId: remoteId,
        dashInfo: resolved.dashInfo!,
        targetPath: targetPath,
        client: _client,
        onFinalized: (file) => _cache.evictIfOverCap(protect: file),
      );
      return (
        url: streamUrl,
        headers: <String, String>{
          'x-flick-sample-rate': resolved.sampleRate.toString(),
          'x-flick-bit-depth': resolved.bitDepth.toString(),
        },
      );
    }

    // 3. Prebuffer direct BTS media locally before handing it to Rust.
    try {
      final cached = await _cache.getPath(
        server.id,
        remoteId,
        extension: resolved.ext ?? 'flac',
      );
      if (cached != null) return null;
    } catch (_) {}
    final targetPath = await _cache.pathFor(
      server.id,
      remoteId,
      extension: resolved.ext ?? 'flac',
    );
    final streamUrl = await TidalStreamProxy.instance.prepareBtsStream(
      trackId: remoteId,
      sourceUrl: resolved.url,
      targetPath: targetPath,
      contentType: switch (resolved.ext) {
        'm4a' => 'audio/mp4',
        'mp3' => 'audio/mpeg',
        _ => 'audio/flac',
      },
      client: _client,
      onFinalized: (file) => _cache.evictIfOverCap(protect: file),
    );
    return (
      url: streamUrl,
      headers: <String, String>{
        'x-flick-sample-rate': resolved.sampleRate.toString(),
        'x-flick-bit-depth': resolved.bitDepth.toString(),
      },
    );
  }

  @override
  Future<String> stream(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
    void Function(double progress)? onProgress,
  }) async {
    final cached = await _cache.getPath(
      server.id,
      remoteId,
      extension: extension,
    );
    if (cached != null) return cached;

    final resolved = await _resolveStreamable(server, remoteId);
    if (resolved == null) {
      throw TidalException('No playable stream for $remoteId.');
    }

    if (resolved.isDash && resolved.dashInfo != null) {
      return _downloadAndAssembleDash(
        server,
        remoteId,
        resolved.dashInfo!,
        onProgress: onProgress,
      );
    }

    final request = http.Request('GET', Uri.parse(resolved.url));
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw TidalException('HTTP ${response.statusCode} for stream $remoteId');
    }
    final total = response.contentLength;
    final builder = BytesBuilder();
    var received = 0;
    await for (final chunk in response.stream) {
      builder.add(chunk);
      received += chunk.length;
      if (onProgress != null && total != null && total > 0) {
        onProgress(received / total);
      }
    }
    return _cache.stash(
      server.id,
      remoteId,
      builder.takeBytes(),
      extension: resolved.ext ?? extension,
    );
  }

  Future<String> _downloadAndAssembleDash(
    NetworkServerEntity server,
    String remoteId,
    DashTrackInfo dashInfo, {
    void Function(double progress)? onProgress,
  }) async {
    final targetPath = await _cache.pathFor(
      server.id,
      remoteId,
      extension: 'mp4',
    );
    final partFile = File('$targetPath.part');
    final sink = partFile.openWrite();

    var isCancelled = false;
    _activeDownloads[remoteId] = () {
      isCancelled = true;
    };

    try {
      // 1. Download initialization segment
      final initResp = await _client
          .get(Uri.parse(dashInfo.initializationUrl))
          .timeout(const Duration(seconds: 30));
      if (initResp.statusCode != 200) {
        throw TidalException(
          'Failed to download DASH init segment: HTTP ${initResp.statusCode}',
        );
      }
      if (isCancelled) throw TidalException('Download cancelled');
      sink.add(initResp.bodyBytes);

      // 2. Download media segments in a pipelined worker pool (up to 8 concurrent workers)
      final totalSegments = dashInfo.segmentUrls.length;
      final completedBuffers = <int, List<int>>{};
      var nextIndexToWrite = 0;
      var hasError = false;
      Object? downloadError;

      const workerCount = 4;
      final concurrency = totalSegments < workerCount
          ? totalSegments
          : workerCount;
      var currentIndex = 0;

      Future<void> worker() async {
        while (!isCancelled && !hasError) {
          int myIndex;
          if (currentIndex >= totalSegments) break;
          myIndex = currentIndex++;
          final myUrl = dashInfo.segmentUrls[myIndex];

          try {
            final resp = await _client
                .get(Uri.parse(myUrl))
                .timeout(const Duration(seconds: 30));
            if (resp.statusCode != 200) {
              throw TidalException(
                'Failed segment $myIndex: HTTP ${resp.statusCode}',
              );
            }
            if (isCancelled) return;

            completedBuffers[myIndex] = resp.bodyBytes;

            // Stream out contiguous segments in exact playback order
            while (completedBuffers.containsKey(nextIndexToWrite)) {
              final segmentData = completedBuffers.remove(nextIndexToWrite)!;
              sink.add(segmentData);
              nextIndexToWrite++;
              if (onProgress != null) {
                onProgress(nextIndexToWrite / (totalSegments + 1));
              }
            }
          } catch (e) {
            hasError = true;
            downloadError = e;
            return;
          }
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));

      if (isCancelled) {
        throw TidalException('Playback download cancelled');
      }
      if (hasError && downloadError != null) {
        throw downloadError!;
      }

      await sink.flush();
      await sink.close();

      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
      await partFile.rename(targetPath);
      try {
        await _cache.evictIfOverCap(protect: File(targetPath));
      } catch (_) {}
      return targetPath;
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      _activeDownloads.remove(remoteId);
    }
  }

  /// Resolve a directly streamable CDN url or DASH track info.
  /// Uses a quality cascade (HI_RES_LOSSLESS -> HI_RES -> LOSSLESS -> HIGH)
  /// to play at maximum available quality.
  Future<TidalStreamResolution?> _resolveStreamable(
    NetworkServerEntity server,
    String trackId,
  ) async {
    const qualityTiers = ['HI_RES_LOSSLESS', 'HI_RES', 'LOSSLESS', 'HIGH'];
    Object? lastError;

    // Start the cascade at the catalog-known max tier when available:
    // tracks tagged non-hi-res can never satisfy the higher tiers, so
    // probing them first only burns API round-trips on every cold start.
    var tierIndex = 0;
    final hintedTier = _tierStartHintByTrackId[trackId];
    if (hintedTier != null) {
      final hintedIndex = qualityTiers.indexOf(hintedTier);
      if (hintedIndex >= 0) tierIndex = hintedIndex;
    }

    for (var i = tierIndex; i < qualityTiers.length; i++) {
      final tier = qualityTiers[i];
      try {
        final info = await _apiGet(
          server,
          '/tracks/$trackId/playbackinfopostpaywall',
          query: {
            'playbackmode': 'STREAM',
            'assetpresentation': 'FULL',
            'audioquality': tier,
          },
        );

        final mime = info['manifestMimeType'] as String?;
        final manifest = info['manifest'] as String?;
        if (manifest == null) continue;

        final rawSampleRate = (info['sampleRate'] as num?)?.toInt();
        final rawBitDepth = (info['bitDepth'] as num?)?.toInt();
        final rawQuality = (info['audioQuality'] as String?) ?? tier;
        final rawCodec = info['codec'] as String?;

        // 1. DASH manifest (Hi-Res Lossless fMP4 FLAC)
        if (mime == 'application/dash+xml') {
          final manifestXml = utf8.decode(base64Decode(manifest));
          final dashInfo = DashManifestParser.parse(manifestXml);
          if (dashInfo != null && dashInfo.segmentUrls.isNotEmpty) {
            final effectiveBandwidth = dashInfo.bandwidth != null
                ? (dashInfo.bandwidth! / 1000).round()
                : null;
            final res = TidalStreamResolution(
              url: '',
              ext: 'mp4',
              isDash: true,
              dashInfo: dashInfo,
              sampleRate: dashInfo.sampleRate ?? rawSampleRate ?? 96000,
              bitDepth: dashInfo.bitDepth ?? rawBitDepth ?? 24,
              audioQuality: rawQuality,
              codec: rawCodec ?? dashInfo.codec ?? 'flac',
              bitrate: effectiveBandwidth,
            );
            _resolvedStreams[trackId] = res;
            return res;
          }
          continue;
        }

        // 2. BTS manifest (Direct unencrypted FLAC/AAC)
        if (mime == 'application/vnd.tidal.bts') {
          final Map<String, dynamic> decoded;
          try {
            decoded =
                jsonDecode(utf8.decode(base64Decode(manifest)))
                    as Map<String, dynamic>;
          } catch (_) {
            continue;
          }

          if (decoded['encryptionType'] != 'NONE') {
            continue; // Skip encrypted streams (DRM/legacy MQA)
          }

          final urls = decoded['urls'] as List<dynamic>?;
          if (urls == null || urls.isEmpty) continue;

          final btsSampleRate = (decoded['sampleRate'] as num?)?.toInt();
          final btsBitDepth = (decoded['bitDepth'] as num?)?.toInt();
          final btsBitrate =
              (decoded['bitRate'] as num?)?.toInt() ??
              (info['bitRate'] as num?)?.toInt();

          final res = TidalStreamResolution(
            url: urls.first as String,
            ext: _extFromMime(decoded['mimeType'] as String?),
            isDash: false,
            dashInfo: null,
            sampleRate: rawSampleRate ?? btsSampleRate ?? 44100,
            bitDepth: rawBitDepth ?? btsBitDepth ?? 16,
            audioQuality: rawQuality,
            codec: rawCodec ?? (decoded['codec'] as String?),
            bitrate: btsBitrate != null && btsBitrate > 10000
                ? (btsBitrate / 1000).round()
                : btsBitrate,
          );
          _resolvedStreams[trackId] = res;
          return res;
        }
      } catch (e) {
        lastError = e;
      }
    }

    if (lastError != null) {
      throw TidalException('No playable stream for $trackId: $lastError');
    }
    throw TidalException(
      'Track $trackId uses an unsupported or encrypted Tidal format (HiRes/MQA/Atmos).',
    );
  }

  @visibleForTesting
  static String? extFromMime(String? mime) => _extFromMime(mime);
  static String? _extFromMime(String? mime) {
    switch (mime) {
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/mpeg':
        return 'mp3';
      default:
        return null;
    }
  }

  // --- Sync --------------------------------------------------------------

  @override
  Stream<ScanProgress> syncLibrary(NetworkServerEntity server) async* {
    final creds = _creds(server.token);
    if (creds == null || creds.userId == null || creds.userId!.isEmpty) {
      throw TidalException('No Tidal sign-in. Tap "Sign in with Tidal".');
    }
    // ponytail: sync the user's favorite tracks (paginated, capped). Favorites
    // map 1:1 to SongEntity with embedded album/artist metadata. Pulling full
    // playlists/my-collection is a follow-up; this is the bounded, predictable
    // surface that fits the existing scan progress UI.
    const pageSize = 100;
    const maxTracks = 2000;
    final syncedRemoteIds = <String>{};
    var offset = 0;
    var songsFound = 0;
    var totalEstimate = 0;

    while (offset < maxTracks) {
      final Map<String, dynamic> payload;
      try {
        payload = await _apiGet(
          server,
          '/users/${creds.userId}/favorites/tracks',
          query: {'limit': '$pageSize', 'offset': '$offset'},
        );
      } catch (e) {
        devLog('Tidal sync page @ $offset failed: $e');
        break;
      }
      final items = (payload['items'] as List<dynamic>?) ?? const [];
      if (items.isEmpty) break;
      totalEstimate =
          (payload['totalNumberOfItems'] as num?)?.toInt() ??
          (offset + items.length);

      final entities = <SongEntity>[];
      for (final raw in items) {
        final item =
            (raw as Map<String, dynamic>)['item'] as Map<String, dynamic>?;
        if (item == null) continue;
        final entity = buildSongEntity(server, item);
        if (entity != null) entities.add(entity);
      }
      if (entities.isNotEmpty) {
        await _repo.upsertSongs(entities);
        syncedRemoteIds.addAll(entities.map((e) => e.remoteId!));
        songsFound += entities.length;
      }

      offset += items.length;
      yield ScanProgress(
        songsFound: songsFound,
        totalFiles: totalEstimate,
        filesProcessed: offset,
        phase: 'Syncing ${server.label}',
      );
      if (items.length < pageSize) break;
    }

    await purgeAndStampNetworkSync(server, syncedRemoteIds);

    yield ScanProgress(
      songsFound: songsFound,
      totalFiles: totalEstimate,
      filesProcessed: offset,
      phase: 'Syncing ${server.label}',
      isComplete: true,
    );
  }

  /// Map a Tidal track object to a [SongEntity]. Returns null when the track
  /// lacks an id. Pure (no network/DB) so it can be unit-tested directly.
  @visibleForTesting
  static SongEntity? buildSongEntity(
    NetworkServerEntity server,
    Map<String, dynamic> t,
  ) {
    final remoteId = t['id']?.toString();
    if (remoteId == null) return null;
    final artists = (t['artists'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>?>();
    final album = t['album'] as Map<String, dynamic>?;
    final durationSec = (t['duration'] as num?)?.toInt();
    final cover = (album?['cover'] as String?) ?? (t['cover'] as String?);
    return SongEntity()
      ..filePath = '${NetworkProtocol.tidal}://${server.id}/$remoteId'
      ..title = (t['title'] as String?) ?? 'Unknown'
      ..artist = (artists != null && artists.isNotEmpty)
          ? (artists.first?['name'] as String? ?? 'Unknown')
          : ((album?['artist'] as Map<String, dynamic>?)?['name'] as String?) ??
                'Unknown'
      ..album = (album?['title'] as String?)
      ..albumArtist =
          ((album?['artist'] as Map<String, dynamic>?)?['name'] as String?)
      ..durationMs = durationSec == null ? null : durationSec * 1000
      ..trackNumber = (t['trackNumber'] as num?)?.toInt()
      ..discNumber = (t['volumeNumber'] as num?)?.toInt()
      ..year = _releaseYear(album?['releaseDate'] as String?)
      ..fileType = _extForQuality(t['audioQuality'] as String?)
      ..albumArtPath = (cover != null && cover.isNotEmpty)
          ? '$_coverMarkerScheme$cover'
          : null
      ..sourceType = NetworkProtocol.tidal
      ..remoteId = remoteId
      ..remoteServerId = server.id
      ..metadataComplete = true
      ..dateAdded = DateTime.now()
      ..lastModified = DateTime.now();
  }

  static int? _releaseYear(String? isoDate) {
    if (isoDate == null || isoDate.length < 4) return null;
    return int.tryParse(isoDate.substring(0, 4));
  }

  static String? extForQuality(String? quality) => _extForQuality(quality);

  static String? _extForQuality(String? quality) {
    switch (quality) {
      case 'HIGH':
        return 'm4a'; // AAC
      case 'LOSSLESS':
      case 'HI_RES_LOSSLESS':
        return 'flac';
      case 'HI_RES':
        return 'flac'; // MQA-in-FLAC; likely unplayable here, surfaced at play.
      default:
        return null;
    }
  }

  // --- Catalog & Search ---------------------------------------------------

  /// Search TIDAL catalog for tracks, albums, artists, and playlists.
  Future<Map<String, dynamic>> searchCatalog(
    NetworkServerEntity server,
    String query, {
    int limit = 25,
    int offset = 0,
    String types = 'TRACKS,ALBUMS,ARTISTS,PLAYLISTS',
  }) async {
    return _apiGet(
      server,
      '/search',
      query: {
        'query': query,
        'limit': '$limit',
        'offset': '$offset',
        'types': types,
      },
    );
  }

  /// Get details for a specific album by its [albumId].
  Future<Map<String, dynamic>> getAlbum(
    NetworkServerEntity server,
    String albumId,
  ) async {
    return _apiGet(server, '/albums/$albumId');
  }

  /// Get track items for a specific album by its [albumId].
  Future<List<Map<String, dynamic>>> getAlbumTracks(
    NetworkServerEntity server,
    String albumId,
  ) async {
    final res = await _apiGet(server, '/albums/$albumId/tracks');
    final items = (res['items'] as List<dynamic>?) ?? [];
    return items.cast<Map<String, dynamic>>();
  }

  /// Get metadata for a specific playlist by its [playlistId].
  Future<Map<String, dynamic>> getPlaylist(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    return _apiGet(server, '/playlists/$playlistId');
  }

  /// Get track items for a specific playlist by its [playlistId].
  Future<List<Map<String, dynamic>>> getPlaylistTracks(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    // Official TIDAL API uses /playlists/{id}/items (wrapping each entry in {"item": ..., "type": "track"}),
    // NOT /playlists/{id}/tracks.
    try {
      final res = await _apiGet(
        server,
        '/playlists/$playlistId/items',
        query: {'limit': '100', 'offset': '0'},
      );
      final rawList = (res['items'] ?? res['data']) as List<dynamic>? ?? [];
      return rawList.whereType<Map<String, dynamic>>().toList();
    } catch (e) {
      devLog(
        '[Tidal] /playlists/$playlistId/items failed ($e), trying /tracks fallback...',
      );
      try {
        final res = await _apiGet(
          server,
          '/playlists/$playlistId/tracks',
          query: {'limit': '100', 'offset': '0'},
        );
        final rawList = (res['items'] ?? res['data']) as List<dynamic>? ?? [];
        return rawList.whereType<Map<String, dynamic>>().toList();
      } catch (e2) {
        devLog('[Tidal] /playlists/$playlistId/tracks failed ($e2)');
        return [];
      }
    }
  }

  /// Get top tracks for a specific artist by [artistId].
  Future<List<Map<String, dynamic>>> getArtistTopTracks(
    NetworkServerEntity server,
    String artistId,
  ) async {
    final res = await _apiGet(server, '/artists/$artistId/toptracks');
    final items = (res['items'] as List<dynamic>?) ?? [];
    return items.cast<Map<String, dynamic>>();
  }

  /// Get details for a specific artist by [artistId].
  Future<Map<String, dynamic>> getArtist(
    NetworkServerEntity server,
    String artistId,
  ) async {
    return _apiGet(server, '/artists/$artistId');
  }

  /// Get albums for a specific artist by [artistId].
  ///
  /// Pass [filter] to narrow results:
  /// - omit or `null` → full-length albums only (TIDAL default)
  /// - `'EPSANDSINGLES'` → EPs and singles
  /// - `'COMPILATIONS'` → compilation albums
  Future<List<Map<String, dynamic>>> getArtistAlbums(
    NetworkServerEntity server,
    String artistId, {
    String? filter,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (filter != null && filter.isNotEmpty) {
      query['filter'] = filter;
    }
    final res = await _apiGet(
      server,
      '/artists/$artistId/albums',
      query: query,
    );
    final items = (res['items'] as List<dynamic>?) ?? [];
    return items.cast<Map<String, dynamic>>();
  }

  /// Get playlists owned or saved by the authenticated user.
  Future<List<Map<String, dynamic>>> getUserPlaylists(
    NetworkServerEntity server,
  ) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return [];
    final res = await _apiGet(
      server,
      '/users/$userId/playlists',
      query: {'limit': '50', 'offset': '0'},
    );
    final items = (res['items'] as List<dynamic>?) ?? [];
    return items.cast<Map<String, dynamic>>();
  }

  /// Fetch the official TIDAL home feed.
  ///
  /// Calls `GET https://api.tidal.com/v2/home/feed/{feedSlug}` with fallback to
  /// `/pages/home` or `/pages/for_you` if V2 is unavailable.
  Future<TidalHomeFeed> getHomeFeed(
    NetworkServerEntity server, {
    String feedSlug = 'static',
    String? cursor,
  }) async {
    final query = <String, String>{};
    if (cursor != null && cursor.isNotEmpty) {
      query['cursor'] = cursor;
    }

    Map<String, dynamic>? raw;
    try {
      raw = await _apiV2Get(server, '/home/feed/$feedSlug', query: query);
    } catch (e) {
      devLog(
        '[Tidal] v2 home feed failed ($e), falling back to v1 multi-endpoints...',
      );
    }

    if (raw != null) {
      final feed = _parseHomeFeed(raw);
      if (feed.sections.isNotEmpty) {
        return feed;
      }
    }

    // SONE parity: if V2 is unavailable or empty, fall back to multi-endpoint V1 approach
    return _fetchV1HomeFeedFallback(server);
  }

  /// SONE-parity V1 fallback: combines /pages/my_collection_my_mixes, /pages/for_you, and /pages/home
  Future<TidalHomeFeed> _fetchV1HomeFeedFallback(
    NetworkServerEntity server,
  ) async {
    final seenTitles = <String>{};
    final allSections = <TidalHomeSection>[];

    void addUniqueSections(List<TidalHomeSection> secs) {
      for (final s in secs) {
        final key = s.title.trim().toLowerCase();
        if (key.isNotEmpty && seenTitles.add(key)) {
          allSections.add(s);
        }
      }
    }

    // 1. User's personal mixes
    try {
      final mixJson = await _apiGet(
        server,
        '/pages/my_collection_my_mixes',
        query: {'deviceType': 'BROWSER', 'locale': 'en_US'},
      );
      addUniqueSections(_parseHomeFeed(mixJson).sections);
    } catch (e) {
      devLog('[Tidal] v1 pages/my_collection_my_mixes failed: $e');
    }

    // 2. For You (personalized recommendations)
    try {
      final forYouJson = await _apiGet(
        server,
        '/pages/for_you',
        query: {'deviceType': 'BROWSER', 'locale': 'en_US'},
      );
      addUniqueSections(_parseHomeFeed(forYouJson).sections);
    } catch (e) {
      devLog('[Tidal] v1 pages/for_you failed: $e');
    }

    // 3. Global Home (The Hits, New Tracks, New Albums, etc.)
    try {
      final homeJson = await _apiGet(
        server,
        '/pages/home',
        query: {'deviceType': 'BROWSER', 'locale': 'en_US'},
      );
      final homeFeed = _parseHomeFeed(homeJson);
      addUniqueSections(homeFeed.sections);
      return TidalHomeFeed(
        tabs: homeFeed.tabs,
        sections: allSections,
        cursor: homeFeed.cursor,
      );
    } catch (e) {
      devLog('[Tidal] v1 pages/home failed: $e');
      return TidalHomeFeed(
        tabs: const [
          TidalHomeTab(name: 'Suggested', type: 'STATIC', slug: 'static'),
        ],
        sections: allSections,
      );
    }
  }

  /// Parses a home feed response, handling V2 and V1 module structures.
  TidalHomeFeed _parseHomeFeed(Map<String, dynamic> json) {
    // 1. Vibes tabs
    final tabs = <TidalHomeTab>[];
    final header = json['header'] as Map<String, dynamic>?;
    final vibes = header?['vibes'] as Map<String, dynamic>?;
    final vibeItems = vibes?['items'] as List<dynamic>?;
    if (vibeItems != null) {
      for (final it in vibeItems) {
        if (it is Map<String, dynamic>) {
          tabs.add(TidalHomeTab.fromJson(it));
        }
      }
    }
    if (tabs.isEmpty) {
      tabs.add(
        const TidalHomeTab(name: 'Suggested', type: 'STATIC', slug: 'static'),
      );
    }

    // 2. Cursor
    final page = json['page'] as Map<String, dynamic>?;
    final cursor = page?['cursor'] as String?;

    // 3. Sections
    final sections = <TidalHomeSection>[];

    // Check V2 format (items as list of sections)
    final topItems = json['items'] as List<dynamic>?;
    if (topItems != null && topItems.isNotEmpty) {
      for (final rawSec in topItems) {
        if (rawSec is! Map<String, dynamic>) continue;
        final secType = rawSec['type'] as String? ?? '';
        final title = _extractSectionTitle(rawSec);
        if (title.isEmpty) continue;

        // Skip non-content promo sections
        if (secType == 'TEXT_BLOCK' ||
            secType == 'SOCIAL' ||
            secType == 'ARTICLE_LIST' ||
            secType == 'FEATURED_PROMOTIONS') {
          continue;
        }

        final secItemsRaw = rawSec['items'] as List<dynamic>?;
        if (secItemsRaw == null || secItemsRaw.isEmpty) continue;

        final items = <TidalHomeItem>[];
        for (final item in secItemsRaw) {
          if (item is Map<String, dynamic>) {
            final parsed = TidalHomeItem.fromJson(item, typeHint: secType);
            if (parsed.id.isNotEmpty || parsed.title.isNotEmpty) {
              items.add(parsed);
            }
          }
        }

        if (items.isNotEmpty) {
          final viewAll = rawSec['viewAll'];
          String? apiPath;
          if (viewAll is String) {
            apiPath = viewAll;
          } else if (viewAll is Map) {
            apiPath = viewAll['apiPath'] as String?;
          }
          apiPath ??= (rawSec['showMore'] as Map?)?['apiPath'] as String?;

          sections.add(
            TidalHomeSection(
              title: title,
              sectionType: secType,
              items: items,
              hasMore: apiPath != null,
              apiPath: apiPath,
            ),
          );
        }
      }
    }

    // Check V1 rows format if sections is empty
    if (sections.isEmpty) {
      final rows = json['rows'] as List<dynamic>?;
      if (rows != null) {
        for (final r in rows) {
          if (r is! Map<String, dynamic>) continue;
          final modules = r['modules'] as List<dynamic>?;
          if (modules == null) continue;
          for (final m in modules) {
            if (m is! Map<String, dynamic>) continue;
            final secType = m['type'] as String? ?? '';
            final title = _extractSectionTitle(m);

            if (secType == 'TEXT_BLOCK' ||
                secType == 'SOCIAL' ||
                secType == 'ARTICLE_LIST' ||
                secType == 'FEATURED_PROMOTIONS') {
              continue;
            }

            List<dynamic>? rawList = m['pagedList']?['items'] as List<dynamic>?;
            rawList ??= (m['highlights'] as List<dynamic>?)
                ?.map((h) => h is Map ? h['item'] : null)
                .where((x) => x != null)
                .toList();
            rawList ??= m['listItems'] as List<dynamic>?;

            if (rawList == null || rawList.isEmpty) continue;

            final items = <TidalHomeItem>[];
            for (final item in rawList) {
              if (item is Map<String, dynamic>) {
                final parsed = TidalHomeItem.fromJson(item, typeHint: secType);
                if (parsed.id.isNotEmpty || parsed.title.isNotEmpty) {
                  items.add(parsed);
                }
              }
            }

            if (items.isNotEmpty) {
              sections.add(
                TidalHomeSection(
                  title: title.isNotEmpty ? title : 'Featured',
                  sectionType: secType,
                  items: items,
                ),
              );
            }
          }
        }
      }
    }

    return TidalHomeFeed(tabs: tabs, sections: sections, cursor: cursor);
  }

  static String _extractSectionTitle(Map<String, dynamic> sec) {
    final title = sec['title'];
    if (title is String && title.isNotEmpty) return title;
    if (title is Map) {
      final text = title['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    final textInfo = sec['titleTextInfo'] as Map<String, dynamic>?;
    if (textInfo?['text'] is String) {
      final text = textInfo!['text'] as String;
      if (text.isNotEmpty) return text;
    }
    final header = sec['header'];
    if (header is String && header.isNotEmpty) return header;
    return '';
  }

  /// Fetch full mix/radio metadata and its tracklist.
  Future<TidalMix> getMix(NetworkServerEntity server, String mixId) async {
    // 1. Primary: /pages/mix?mixId={mixId}
    try {
      final res = await _apiGet(
        server,
        '/pages/mix',
        query: {
          'mixId': mixId,
          'countryCode': _countryCode(server.token),
          'deviceType': 'BROWSER',
          'locale': 'en_US',
        },
      );
      final rows = res['rows'] as List<dynamic>?;
      if (rows != null && rows.isNotEmpty) {
        String title = 'Mix';
        String? subtitle;
        String? mixType;
        String? image;
        final tracks = <Song>[];

        for (final row in rows) {
          final modules = (row as Map)['modules'] as List<dynamic>?;
          if (modules == null) continue;
          for (final m in modules) {
            final mod = m as Map<String, dynamic>;
            final modType = mod['type'] as String? ?? '';
            if (modType == 'MIX_HEADER') {
              final mixObj = mod['mix'] as Map<String, dynamic>?;
              if (mixObj != null) {
                title = (mixObj['title'] as String?) ?? title;
                subtitle = mixObj['subTitle'] as String?;
                mixType = mixObj['mixType'] as String?;
                final images = mixObj['images'] as Map<String, dynamic>?;
                image =
                    (images?['LARGE']?['url'] as String?) ??
                    (images?['MEDIUM']?['url'] as String?) ??
                    (images?['SMALL']?['url'] as String?);
              }
            } else if (modType == 'TRACK_LIST') {
              final items = mod['pagedList']?['items'] as List<dynamic>?;
              if (items != null) {
                for (final item in items) {
                  if (item is Map<String, dynamic>) {
                    final trackData =
                        (item['item'] as Map<String, dynamic>?) ?? item;
                    tracks.add(makeEphemeralSong(server, trackData));
                  }
                }
              }
            }
          }
        }

        if (tracks.isNotEmpty) {
          return TidalMix(
            mixId: mixId,
            title: title,
            subTitle: subtitle,
            imageUrl: image,
            mixType: mixType,
            tracks: tracks,
          );
        }
      }
    } catch (e) {
      devLog(
        '[Tidal] /pages/mix failed for $mixId ($e), falling back to /mixes/$mixId/items',
      );
    }

    // 2. Fallback: /mixes/{id}/items
    final fallbackRes = await _apiGet(
      server,
      '/mixes/$mixId/items',
      query: {'countryCode': _countryCode(server.token)},
    );
    final items = (fallbackRes['items'] as List<dynamic>?) ?? [];
    final tracks = <Song>[];
    for (final item in items) {
      if (item is Map<String, dynamic>) {
        final trackData = (item['item'] as Map<String, dynamic>?) ?? item;
        tracks.add(makeEphemeralSong(server, trackData));
      }
    }
    return TidalMix(mixId: mixId, title: 'Mix', tracks: tracks);
  }

  /// Fetch user favorite/custom mixes (Daily Discovery, My Mix 1..8, Artist Mixes)
  /// from `GET https://api.tidal.com/v2/favorites/mixes`, with fallback to `/pages/my_collection_my_mixes`.
  Future<List<TidalHomeItem>> getFavoriteMixes(
    NetworkServerEntity server, {
    int limit = 50,
    int offset = 0,
  }) async {
    final query = {
      'limit': limit.toString(),
      'offset': offset.toString(),
      'order': 'DATE',
      'orderDirection': 'DESC',
    };

    List<dynamic>? rawItems;
    try {
      final res = await _apiV2Get(server, '/favorites/mixes', query: query);
      rawItems =
          (res['items'] as List<dynamic>?) ?? (res['data'] as List<dynamic>?);
    } catch (e) {
      devLog('[Tidal] v2 /favorites/mixes failed ($e)');
    }

    final mixes = <TidalHomeItem>[];
    for (final item in (rawItems ?? const [])) {
      if (item is Map<String, dynamic>) {
        final parsed = TidalHomeItem.fromJson(item, typeHint: 'MIX_LIST');
        if (parsed.id.isNotEmpty || parsed.title.isNotEmpty) {
          mixes.add(parsed);
        }
      }
    }

    if (mixes.isNotEmpty) return mixes;

    // Fallback: If v2 returned no items or failed, check /pages/my_collection_my_mixes
    try {
      final pageRes = await _apiGet(
        server,
        '/pages/my_collection_my_mixes',
        query: {'deviceType': 'BROWSER', 'locale': 'en_US'},
      );
      final pageFeed = _parseHomeFeed(pageRes);
      for (final sec in pageFeed.sections) {
        for (final item in sec.items) {
          if (item.isMix || item.type.toUpperCase().contains('MIX')) {
            mixes.add(item);
          }
        }
      }
    } catch (e) {
      devLog('[Tidal] fallback /pages/my_collection_my_mixes failed: $e');
    }

    return mixes;
  }

  /// Fetches track metadata by id (returns full JSON including `mixes` dictionary).
  Future<Map<String, dynamic>> getTrackDetail(
    NetworkServerEntity server,
    String trackId,
  ) async {
    return _apiGet(server, '/tracks/$trackId');
  }

  /// Fetches artist metadata by id (returns full JSON including `mixes` dictionary).
  Future<Map<String, dynamic>> getArtistDetail(
    NetworkServerEntity server,
    String artistId,
  ) async {
    return _apiGet(server, '/artists/$artistId');
  }

  /// Resolves the Radio Mix ID for a track.
  /// If [cachedMixes] already contains TRACK_MIX, returns it.
  /// Otherwise, fetches the track detail on-demand (matching SONE behavior).
  Future<String?> getTrackRadioMixId(
    NetworkServerEntity server,
    String trackId, {
    Map<String, dynamic>? cachedMixes,
  }) async {
    final cached = cachedMixes?['TRACK_MIX']?.toString();
    if (cached != null && cached.isNotEmpty) return cached;

    try {
      final detail = await getTrackDetail(server, trackId);
      final mixId = (detail['mixes'] as Map?)?['TRACK_MIX']?.toString();
      if (mixId != null && mixId.isNotEmpty) {
        return mixId;
      }
    } catch (e) {
      devLog('[Tidal] Failed to get TRACK_MIX for track $trackId: $e');
    }
    return null;
  }

  /// Resolves the Radio Mix ID for a TidalHomeItem (track, artist, or mix).
  Future<String?> resolveRadioMixId(
    NetworkServerEntity server,
    TidalHomeItem item,
  ) async {
    final cached =
        item.raw['mixes']?['TRACK_MIX']?.toString() ??
        item.raw['mixes']?['ARTIST_MIX']?.toString() ??
        (item.isMix ? (item.raw['mixId']?.toString() ?? item.id) : null);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (item.isTrack && item.id.isNotEmpty) {
      final mixId = await getTrackRadioMixId(server, item.id);
      if (mixId != null) {
        item.raw['mixes'] = {'TRACK_MIX': mixId};
        return mixId;
      }
    }

    if (item.isArtist && item.id.isNotEmpty) {
      try {
        final detail = await getArtistDetail(server, item.id);
        final mixId = (detail['mixes'] as Map?)?['ARTIST_MIX']?.toString();
        if (mixId != null && mixId.isNotEmpty) {
          item.raw['mixes'] = detail['mixes'];
          return mixId;
        }
      } catch (e) {
        devLog('[Tidal] Failed to get ARTIST_MIX for artist ${item.id}: $e');
      }
    }

    return null;
  }

  /// Parse the payload of an unverified JWT access token to retrieve account claims.
  static ({int? uid, int? cid, String? sid}) _parseJwtClaims(
    String accessToken,
  ) {
    final parts = accessToken.split('.');
    if (parts.length < 2) return (uid: null, cid: null, sid: null);
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decodedBytes = base64Url.decode(normalized);
      final json =
          jsonDecode(utf8.decode(decodedBytes)) as Map<String, dynamic>;
      final uid = (json['uid'] as num?)?.toInt();
      final cid = (json['cid'] as num?)?.toInt();
      final sid = json['sid'] as String?;
      return (uid: uid, cid: cid, sid: sid);
    } catch (_) {
      return (uid: null, cid: null, sid: null);
    }
  }

  /// Generate a random RFC4122 v4 UUID string.
  static String _randomUuid() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Reports a playback session to TIDAL's Event Collector (ec.tidal.com)
  /// so that "Recently Played", user listening history, and dynamic mix/feed
  /// recommendations stay in sync with the user's TIDAL account.
  Future<void> reportPlayback(
    NetworkServerEntity server, {
    required String trackId,
    required int durationSeconds,
    PlaybackContext? context,
  }) async {
    try {
      final creds = await _ensureValidToken(server);
      final claims = _parseJwtClaims(creds.accessToken);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final startMs = nowMs - (durationSeconds * 1000);
      final sessionId = _randomUuid();

      String sourceType = 'ITEM';
      String sourceId = trackId;

      if (context != null) {
        switch (context.source) {
          case PlaybackSource.album:
            sourceType = 'ALBUM';
            sourceId = context.sourceId ?? trackId;
            break;
          case PlaybackSource.playlist:
            sourceType = 'PLAYLIST';
            sourceId = context.sourceId ?? trackId;
            break;
          case PlaybackSource.artist:
            sourceType = 'ARTIST';
            sourceId = context.sourceId ?? trackId;
            break;
          default:
            sourceType = 'ITEM';
            sourceId = trackId;
            break;
        }
      }

      final payload = <String, dynamic>{
        'playbackSessionId': sessionId,
        'isPostPaywall': true,
        'productType': 'TRACK',
        'requestedProductId': trackId,
        'actualProductId': trackId,
        'actualAssetPresentation': 'FULL',
        'actualAudioMode': 'STEREO',
        'actualQuality': 'LOSSLESS',
        'startTimestamp': startMs,
        'endTimestamp': nowMs,
        'startAssetPosition': 0.0,
        'endAssetPosition': durationSeconds.toDouble(),
        'actions': <dynamic>[],
        'sourceType': sourceType,
        'sourceId': sourceId,
      };

      final bodyJson = jsonEncode({
        'group': 'play_log',
        'version': 2,
        'ts': nowMs,
        'uuid': _randomUuid(),
        'user': {
          if (claims.uid != null) 'id': claims.uid,
          if (claims.cid != null) 'clientId': claims.cid,
          if (claims.sid != null) 'sessionId': claims.sid,
        },
        'client': {
          'token': claims.cid?.toString() ?? '',
          'deviceType': 'mobile',
          'version': '2.205.0',
          'platform': 'android',
        },
        'payload': payload,
      });

      final headersJson = jsonEncode({
        'client-id': clientId,
        'app-version': '2.205.0',
        'os-name': 'Android',
        'os-version': '35',
        'device-model': 'Pixel 7',
        'device-vendor': 'Google',
        'consent-category': 'NECESSARY',
        'requested-sent-timestamp': nowMs.toString(),
        'authorization': creds.accessToken,
      });

      final formFields = <String, String>{
        'SendMessageBatchRequestEntry.1.Id': _randomUuid(),
        'SendMessageBatchRequestEntry.1.MessageBody': bodyJson,
        'SendMessageBatchRequestEntry.1.MessageAttribute.1.Name': 'Name',
        'SendMessageBatchRequestEntry.1.MessageAttribute.1.Value.StringValue':
            'playback_session',
        'SendMessageBatchRequestEntry.1.MessageAttribute.1.Value.DataType':
            'String',
        'SendMessageBatchRequestEntry.1.MessageAttribute.2.Name': 'Headers',
        'SendMessageBatchRequestEntry.1.MessageAttribute.2.Value.StringValue':
            headersJson,
        'SendMessageBatchRequestEntry.1.MessageAttribute.2.Value.DataType':
            'String',
      };

      final res = await _client
          .post(
            Uri.parse(_eventCollectorUrl),
            headers: {
              'Authorization': 'Bearer ${creds.accessToken}',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: formFields,
          )
          .timeout(const Duration(seconds: 10));

      devLog(
        '[Tidal] reportPlayback for track $trackId ($sourceType:$sourceId) -> HTTP ${res.statusCode}',
      );
    } catch (e) {
      devLog('[Tidal] reportPlayback failed: $e');
    }
  }

  /// Get the list of favorite track IDs in the user's TIDAL account.
  Future<Set<String>> getFavoriteTrackIds(NetworkServerEntity server) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return {};
    try {
      final res = await _apiGet(
        server,
        '/users/$userId/favorites/tracks',
        query: {'limit': '2000'},
      );
      final items = res['items'] as List<dynamic>?;
      if (items == null) return {};
      final ids = <String>{};
      for (final it in items) {
        if (it is Map<String, dynamic>) {
          final item = it['item'] as Map<String, dynamic>?;
          final id = item?['id']?.toString() ?? it['id']?.toString();
          if (id != null && id.isNotEmpty) {
            ids.add(id);
          }
        }
      }
      return ids;
    } catch (e) {
      devLog('[Tidal] getFavoriteTrackIds error: $e');
      return {};
    }
  }

  /// Add a track to TIDAL favorites.
  Future<void> addFavoriteTrack(
    NetworkServerEntity server,
    String trackId,
  ) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return;
    final url = '$_apiBase/users/$userId/favorites/tracks';
    final res = await _apiAuthPostForm(server, url, {'trackId': trackId});
    if (res.statusCode >= 400) {
      devLog(
        '[Tidal] addFavoriteTrack failed: HTTP ${res.statusCode} ${res.body}',
      );
      throw TidalException(
        'Failed to add to TIDAL favorites: HTTP ${res.statusCode}',
      );
    }
  }

  /// Remove a track from TIDAL favorites.
  Future<void> removeFavoriteTrack(
    NetworkServerEntity server,
    String trackId,
  ) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return;
    final url = '$_apiBase/users/$userId/favorites/tracks/$trackId';
    final res = await _apiAuthDelete(server, url);
    if (res.statusCode >= 400) {
      devLog(
        '[Tidal] removeFavoriteTrack failed: HTTP ${res.statusCode} ${res.body}',
      );
      throw TidalException(
        'Failed to remove from TIDAL favorites: HTTP ${res.statusCode}',
      );
    }
  }

  /// Create a new playlist in the user's TIDAL account.
  Future<Map<String, dynamic>> createPlaylist(
    NetworkServerEntity server, {
    required String title,
    String description = '',
  }) async {
    final cc = _countryCode(server.token);
    final payload = {
      'data': {
        'type': 'playlists',
        'attributes': {
          'name': title,
          'description': description,
          'accessType': 'PUBLIC',
        },
      },
    };

    // 1. Try OpenAPI POST /v2/playlists
    try {
      final url = cc.isNotEmpty
          ? '$_openapiBase/playlists?countryCode=$cc'
          : '$_openapiBase/playlists';
      final res = await _apiAuthPostJson(server, url, payload);
      if (res.statusCode < 300) {
        final parsed = jsonDecode(res.body) as Map<String, dynamic>;
        final data = parsed['data'] as Map<String, dynamic>? ?? parsed;
        return data;
      }
      devLog(
        '[Tidal] OpenAPI createPlaylist returned HTTP ${res.statusCode}: ${res.body}',
      );
    } catch (e) {
      devLog('[Tidal] OpenAPI createPlaylist error: $e');
    }

    // 2. Fallback: V1 POST /users/{userId}/playlists
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId != null && userId.isNotEmpty) {
      try {
        final form = <String, String>{
          'title': title,
          'description': description,
        };
        final v1Res = await _apiAuthPostForm(
          server,
          '$_apiBase/users/$userId/playlists',
          form,
        );
        if (v1Res.statusCode < 300) {
          final parsed = jsonDecode(v1Res.body) as Map<String, dynamic>;
          return parsed;
        }
        devLog(
          '[Tidal] V1 createPlaylist returned HTTP ${v1Res.statusCode}: ${v1Res.body}',
        );
      } catch (e2) {
        devLog('[Tidal] V1 createPlaylist error: $e2');
      }
    }

    throw TidalException('Failed to create TIDAL playlist "$title".');
  }

  /// Add a track to a TIDAL playlist using the required ETag header.
  Future<void> addTrackToPlaylist(
    NetworkServerEntity server, {
    required String playlistId,
    required String trackId,
  }) async {
    // Sanitize trackId: if passed with 'tidal_xxx_' prefix, extract pure numeric id
    final cleanTrackId = trackId.contains('_')
        ? trackId.split('_').last
        : trackId;

    // 1. Get playlist ETag
    final playlistInfo = await _getPlaylistWithEtag(server, playlistId);
    final etag = playlistInfo.etag ?? '*';

    // 2. Post item with If-None-Match header
    final url = '$_apiBase/playlists/$playlistId/items';
    final res = await _apiAuthPostForm(
      server,
      url,
      {
        'trackIds': cleanTrackId,
        'onDupes': 'SKIP',
        'onArtifactNotFound': 'FAIL',
      },
      headers: {'If-None-Match': etag},
    );
    if (res.statusCode >= 400) {
      devLog(
        '[Tidal] addTrackToPlaylist failed: HTTP ${res.statusCode} ${res.body}',
      );
      throw TidalException(
        'Failed to add track to playlist: HTTP ${res.statusCode}',
      );
    }
  }

  /// Add multiple tracks to a TIDAL playlist in batches (chunked by 50).
  Future<void> addTracksToPlaylist(
    NetworkServerEntity server, {
    required String playlistId,
    required List<String> trackIds,
  }) async {
    if (trackIds.isEmpty) return;

    final cleanTrackIds = trackIds
        .map((id) {
          return id.contains('_') ? id.split('_').last : id;
        })
        .where((id) => id.trim().isNotEmpty)
        .toList();

    if (cleanTrackIds.isEmpty) return;

    const chunkSize = 50;
    for (int i = 0; i < cleanTrackIds.length; i += chunkSize) {
      final end = (i + chunkSize < cleanTrackIds.length)
          ? i + chunkSize
          : cleanTrackIds.length;
      final chunk = cleanTrackIds.sublist(i, end);

      // 1. Get latest playlist ETag for this batch
      final playlistInfo = await _getPlaylistWithEtag(server, playlistId);
      final etag = playlistInfo.etag ?? '*';

      // 2. Post batch of items with If-None-Match header
      final url = '$_apiBase/playlists/$playlistId/items';
      final res = await _apiAuthPostForm(
        server,
        url,
        {
          'trackIds': chunk.join(','),
          'onDupes': 'SKIP',
          'onArtifactNotFound': 'FAIL',
        },
        headers: {'If-None-Match': etag},
      );
      if (res.statusCode >= 400) {
        devLog(
          '[Tidal] addTracksToPlaylist batch failed: HTTP ${res.statusCode} ${res.body}',
        );
        throw TidalException(
          'Failed to add tracks to playlist: HTTP ${res.statusCode}',
        );
      }
    }
  }

  /// Clean song title by stripping extraneous version/edition noise.
  static String _cleanSongTitle(String title) {
    var t = title.trim();
    // Remove featured artists: (feat. ...), [feat. ...], (ft. ...), [ft. ...]
    t = t.replaceAll(
      RegExp(r'\s*[\(\[](?:feat|ft)\.?\s+[^\)\]]+[\)\]]', caseSensitive: false),
      '',
    );
    // Remove common edition suffixes in parentheses/brackets
    t = t.replaceAll(
      RegExp(
        r'\s*[\(\[][^\)\]]*(?:single|ep|remaster|edit|version|official|bonus|ost|soundtrack)[^\)\]]*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    // Remove " - Single", " - EP", " - Remastered..." at the end of string
    t = t.replaceAll(
      RegExp(
        r'\s*-\s*(?:single|ep|remastered|remaster|radio edit|edit|version)\b.*$',
        caseSensitive: false,
      ),
      '',
    );
    // Remove double quotes and collapse excessive whitespace
    t = t
        .replaceAll('"', '')
        .replaceAll("'", "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.isNotEmpty ? t : title.trim();
  }

  /// Clean artist name by stripping bracketed CV/role information.
  static String _cleanArtistName(String artist) {
    var a = artist.trim();
    // Remove bracketed CV info, e.g. "桜高軽音部 [平沢唯... (CV:...)]"
    a = a.replaceAll(RegExp(r'\s*\[[^\]]*\]'), '');
    a = a.replaceAll(RegExp(r'\s*\([^)]*CV:[^)]*\)', caseSensitive: false), '');
    // If there is " & ", prioritize primary artist for catalog search
    if (a.contains(' & ')) {
      final parts = a.split(' & ');
      if (parts.first.trim().isNotEmpty) {
        a = parts.first.trim();
      }
    }
    a = a.replaceAll('"', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return a.isNotEmpty ? a : artist.trim();
  }

  /// Evaluates track candidate similarity score (0 to 100+).
  static int _evaluateTrackMatch(
    Map<String, dynamic> track, {
    required String rawTitle,
    required String cleanTitle,
    required String rawArtist,
    required String cleanArtist,
    int? expectedDurationMs,
    String? expectedIsrc,
  }) {
    int score = 0;

    // 1. Direct ISRC check on candidate metadata if present
    final candIsrc = track['isrc']?.toString().trim();
    if (expectedIsrc != null &&
        expectedIsrc.isNotEmpty &&
        candIsrc != null &&
        candIsrc.isNotEmpty) {
      if (candIsrc.toUpperCase() == expectedIsrc.toUpperCase()) {
        return 100;
      }
    }

    final candTitle = (track['title']?.toString() ?? '').toLowerCase().trim();
    final candArtistsList =
        (track['artists'] as List<dynamic>?)
            ?.map(
              (e) =>
                  (e as Map?)?['name']?.toString().toLowerCase().trim() ?? '',
            )
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];
    final primaryCandArtist = candArtistsList.isNotEmpty
        ? candArtistsList.first
        : ((track['artist'] as Map?)?['name']
                  ?.toString()
                  .toLowerCase()
                  .trim() ??
              '');

    final targetCleanTitle = cleanTitle.toLowerCase();
    final targetCleanArtist = cleanArtist.toLowerCase();
    final targetRawArtist = rawArtist.toLowerCase().trim();

    // 2. Title matching
    if (candTitle == targetCleanTitle ||
        candTitle == rawTitle.toLowerCase().trim()) {
      score += 45;
    } else if (candTitle.contains(targetCleanTitle) ||
        targetCleanTitle.contains(candTitle)) {
      score += 35;
    } else {
      final targetWords = targetCleanTitle
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toSet();
      final candWords = candTitle
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toSet();
      final commonWords = targetWords.intersection(candWords);
      if (commonWords.isNotEmpty &&
          commonWords.length >= (targetWords.length * 0.5)) {
        score += 25;
      } else {
        score -= 20; // Major title mismatch
      }
    }

    // 3. Artist matching
    bool artistMatched = false;
    for (final a in candArtistsList) {
      if (a == targetCleanArtist ||
          a == targetRawArtist ||
          a.contains(targetCleanArtist) ||
          targetCleanArtist.contains(a) ||
          targetRawArtist.contains(a)) {
        artistMatched = true;
        break;
      }
    }
    if (!artistMatched && primaryCandArtist.isNotEmpty) {
      if (primaryCandArtist == targetCleanArtist ||
          primaryCandArtist == targetRawArtist ||
          primaryCandArtist.contains(targetCleanArtist) ||
          targetCleanArtist.contains(primaryCandArtist) ||
          targetRawArtist.contains(primaryCandArtist)) {
        artistMatched = true;
      }
    }

    if (artistMatched) {
      score += 35;
    } else {
      final targetArtistWords = targetCleanArtist
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toSet();
      final candArtistWords = primaryCandArtist
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toSet();
      final commonArtistWords = targetArtistWords.intersection(candArtistWords);
      if (commonArtistWords.isNotEmpty) {
        score += 15;
      } else {
        score -= 25; // Artist mismatch penalty
      }
    }

    // 4. Duration validation
    if (expectedDurationMs != null && expectedDurationMs > 0) {
      final expectedSec = (expectedDurationMs / 1000).round();
      final candSec = (track['duration'] as num?)?.toInt() ?? 0;
      if (candSec > 0) {
        final diff = (candSec - expectedSec).abs();
        if (diff <= 3) {
          score += 20; // Exact duration match bonus
        } else if (diff <= 8) {
          score += 10;
        } else if (diff > 20) {
          score -= 30; // Heavy penalty for mismatched version
        }
      }
    }

    return score;
  }

  /// Search a track on TIDAL with smart sanitization, multi-query candidate pooling,
  /// confidence scoring, and duration verification.
  /// Returns the TIDAL numeric trackId if a high-confidence match is found, or null otherwise.
  Future<String?> searchTrackByIsrcOrText(
    NetworkServerEntity server, {
    String? isrc,
    required String title,
    required String artist,
    int? expectedDurationMs,
  }) async {
    final cleanIsrc = isrc?.trim();
    final cleanTitle = _cleanSongTitle(title);
    final cleanArtist = _cleanArtistName(artist);

    // Strategy 1: Search by ISRC if available
    if (cleanIsrc != null && cleanIsrc.isNotEmpty) {
      try {
        final res = await _apiGet(
          server,
          '/search',
          query: {'query': cleanIsrc, 'types': 'TRACKS', 'limit': '3'},
        );
        final tracks = (res['tracks']?['items'] as List<dynamic>?) ?? [];
        for (final t in tracks) {
          if (t is Map<String, dynamic>) {
            final score = _evaluateTrackMatch(
              t,
              rawTitle: title,
              cleanTitle: cleanTitle,
              rawArtist: artist,
              cleanArtist: cleanArtist,
              expectedDurationMs: expectedDurationMs,
              expectedIsrc: cleanIsrc,
            );
            // If the ISRC result is verified with high confidence, accept immediately!
            if (score >= 65) {
              return t['id']?.toString();
            }
          }
        }
      } catch (e) {
        devLog('[Tidal] search by ISRC ($cleanIsrc) failed: $e');
      }
    }

    final candidatePool = <Map<String, dynamic>>[];
    final seenTrackIds = <String>{};

    void addCandidates(List<dynamic>? tracks) {
      if (tracks == null) return;
      for (final t in tracks) {
        if (t is Map<String, dynamic>) {
          final id = t['id']?.toString();
          if (id != null && seenTrackIds.add(id)) {
            candidatePool.add(t);
          }
        }
      }
    }

    // Strategy 2: Search by Clean Title + Clean Artist
    if (cleanTitle.isNotEmpty) {
      try {
        final queryText = '$cleanTitle $cleanArtist'.trim();
        final res = await _apiGet(
          server,
          '/search',
          query: {'query': queryText, 'types': 'TRACKS', 'limit': '5'},
        );
        addCandidates(res['tracks']?['items'] as List<dynamic>?);
      } catch (e) {
        devLog('[Tidal] search by text ($cleanTitle $cleanArtist) failed: $e');
      }
    }

    // Strategy 3: Fallback search by Clean Title alone if pool is empty
    if (candidatePool.isEmpty && cleanTitle.isNotEmpty) {
      try {
        final res = await _apiGet(
          server,
          '/search',
          query: {'query': cleanTitle, 'types': 'TRACKS', 'limit': '5'},
        );
        addCandidates(res['tracks']?['items'] as List<dynamic>?);
      } catch (e) {
        devLog('[Tidal] search by title ($cleanTitle) failed: $e');
      }
    }

    if (candidatePool.isEmpty) return null;

    // Evaluate all candidates and pick the highest scoring candidate
    Map<String, dynamic>? bestCandidate;
    int highestScore = -100;

    for (final cand in candidatePool) {
      final score = _evaluateTrackMatch(
        cand,
        rawTitle: title,
        cleanTitle: cleanTitle,
        rawArtist: artist,
        cleanArtist: cleanArtist,
        expectedDurationMs: expectedDurationMs,
        expectedIsrc: cleanIsrc,
      );

      if (score > highestScore) {
        highestScore = score;
        bestCandidate = cand;
      }
    }

    // Reject low-confidence candidates (score < 50) to prevent adding random songs
    if (bestCandidate != null && highestScore >= 50) {
      return bestCandidate['id']?.toString();
    }

    devLog(
      '[Tidal] Match rejected for "$title" by "$artist" (best candidate: ${bestCandidate?['title']} by ${bestCandidate?['artist']?['name']}, score: $highestScore < 50)',
    );
    return null;
  }

  /// Build an on-the-fly ephemeral [Song] from a TIDAL track JSON object.
  ///
  /// This allows instant playback of searched or browsed catalog tracks
  /// without requiring prior library synchronization to the local database.
  Song buildEphemeralSong(
    NetworkServerEntity server,
    Map<String, dynamic> trackJson,
  ) => makeEphemeralSong(server, trackJson);

  /// Static helper to construct an ephemeral [Song] from a TIDAL track JSON object.
  static Song makeEphemeralSong(
    NetworkServerEntity server,
    Map<String, dynamic> rawTrackJson,
  ) {
    final trackJson =
        rawTrackJson.containsKey('item') &&
            rawTrackJson['item'] is Map<String, dynamic>
        ? rawTrackJson['item'] as Map<String, dynamic>
        : rawTrackJson;
    final rawId = trackJson['id'];
    final remoteId = rawId?.toString() ?? '';
    final artists = (trackJson['artists'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>?>();
    final album = trackJson['album'] as Map<String, dynamic>?;
    final durationSec = (trackJson['duration'] as num?)?.toInt() ?? 0;
    final cover =
        (album?['cover'] as String?) ??
        (trackJson['cover'] as String?) ??
        (trackJson['imageId'] as String?) ??
        (rawTrackJson['imageId'] as String?) ??
        (album?['picture'] as String?);
    final quality = trackJson['audioQuality'] as String?;
    final mediaMetadata = trackJson['mediaMetadata'] as Map<String, dynamic>?;
    final tags =
        (mediaMetadata?['tags'] as List<dynamic>?)?.cast<String>() ?? [];
    final isHiRes =
        tags.contains('HIRES_LOSSLESS') ||
        tags.contains('HIRES_LOSSLESS_MQA') ||
        quality == 'HI_RES_LOSSLESS';
    // Remember the catalog-known max tier so the stream-resolution cascade
    // can skip higher tiers this track can never satisfy. Hi-res tracks
    // keep the full cascade (subscription/region may still downgrade them);
    // unknown quality keeps it too as the safe fallback.
    if (remoteId.isNotEmpty && !isHiRes) {
      final startTier = switch (quality) {
        'HI_RES' => 'HI_RES',
        'LOSSLESS' => 'LOSSLESS',
        'HIGH' => 'HIGH',
        _ => null,
      };
      if (startTier != null) {
        _tierStartHintByTrackId[remoteId] = startTier;
      }
    }
    final initialSampleRate = isHiRes ? 96000 : 44100;
    final initialBitDepth = isHiRes ? 24 : 16;
    final initialResolution = isHiRes
        ? '24-bit / 96kHz'
        : (quality == 'HIGH' ? '320kbps' : '16-bit / 44.1kHz / 1411kbps');

    final coverUrl = (cover != null && cover.isNotEmpty)
        ? TidalService.coverUrl(cover, size: 640)
        : null;

    return Song(
      id: 'tidal_${server.id}_$remoteId',
      title: (trackJson['title'] as String?) ?? 'Unknown Track',
      artist: (artists != null && artists.isNotEmpty)
          ? (artists.first?['name'] as String? ?? 'Unknown Artist')
          : ((album?['artist'] as Map<String, dynamic>?)?['name'] as String? ??
                'Unknown Artist'),
      album: album?['title'] as String?,
      albumArt: (coverUrl != null && coverUrl.isNotEmpty) ? coverUrl : null,
      duration: Duration(seconds: durationSec),
      fileType: isHiRes ? 'flac' : (extForQuality(quality) ?? 'flac'),
      sampleRate: initialSampleRate,
      bitDepth: initialBitDepth,
      resolution: initialResolution,
      trackNumber: (trackJson['trackNumber'] as num?)?.toInt(),
      discNumber: (trackJson['volumeNumber'] as num?)?.toInt(),
      year: _releaseYear(album?['releaseDate'] as String?),
      filePath: '${NetworkProtocol.tidal}://${server.id}/$remoteId',
      sourceType: NetworkProtocol.tidal,
      remoteId: remoteId,
      remoteServerId: server.id,
    );
  }
}

class _TidalCreds {
  const _TidalCreds({
    required this.accessToken,
    this.refreshToken,
    this.userId,
    required this.countryCode,
    this.expiresAtMs,
  });
  final String accessToken;
  final String? refreshToken;
  final String? userId;
  final String countryCode;
  final int? expiresAtMs;
}

class TidalException implements Exception {
  final String message;

  /// For device-flow launch failures (no callback path): the verification URL
  /// the user can open manually to finish signing in.
  final String? verificationUri;
  TidalException(this.message, {this.verificationUri});
  @override
  String toString() => message;
}

/// Resolved stream metadata and endpoint details for a TIDAL track.
class TidalStreamResolution {
  final String url;
  final String? ext;
  final bool isDash;
  final DashTrackInfo? dashInfo;
  final int sampleRate;
  final int bitDepth;
  final String audioQuality;
  final String? codec;

  final int? bitrate;

  int? get effectiveBitrate {
    if (bitrate != null && bitrate! > 0) return bitrate;
    if (dashInfo?.bandwidth != null) {
      return (dashInfo!.bandwidth! / 1000).round();
    }
    if ((audioQuality == 'LOSSLESS' || bitDepth <= 16) && sampleRate == 44100) {
      return 1411;
    }
    return null;
  }

  const TidalStreamResolution({
    required this.url,
    this.ext,
    required this.isDash,
    this.dashInfo,
    required this.sampleRate,
    required this.bitDepth,
    required this.audioQuality,
    this.codec,
    this.bitrate,
  });

  String get resolutionString {
    final parts = <String>[];
    parts.add('$bitDepth-bit');
    final khz = sampleRate / 1000;
    final khzStr = sampleRate % 1000 == 0
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    parts.add('${khzStr}kHz');
    final kbps = effectiveBitrate;
    if (kbps != null && kbps > 0) {
      parts.add('${kbps}kbps');
    }
    return parts.join(' / ');
  }
}
