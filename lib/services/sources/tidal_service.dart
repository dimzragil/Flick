import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/app_log.dart';
import '../../core/utils/dev_log.dart';
import '../../data/database.dart';
import 'package:isar_community/isar.dart';
import '../../data/repositories/song_repository.dart';
import '../../models/playback_context.dart';
import '../../models/song.dart';
import '../../models/sources/tidal_lyrics.dart';
import '../../models/sources/tidal_models.dart';
import '../library_scanner_service.dart' show ScanProgress;
import '../network_cache_service.dart';
import 'dash_direct_delivery.dart';
import 'dash_manifest_parser.dart';
import 'network_source_service.dart';
import 'tidal_token_store.dart';

/// Tidal client over the reverse-engineered web/OAuth2 surface.
///
/// Auth is Tidal's OAuth2 **device-authorization grant**: the app impersonates a
/// Tidal web/desktop client using its public `clientId` and the user authorizes
/// on their own device with their own Tidal account. Tokens (access + refresh)
/// are persisted as a JSON blob in [NetworkServerEntity.token] and refreshed
/// transparently on expiry, writing the new token back to the DB.
///
/// Playback: `/tracks/{id}/playbackinfopostpaywall` returns either a
/// `vnd.tidal.bts` manifest (a direct unencrypted FLAC/AAC CDN URL) or an
/// embedded DASH manifest (Hi-Res fMP4 FLAC). Both are played **directly from
/// the TIDAL CDN**: the engine is handed the CDN file URL, or — for DASH,
/// whose manifest is not hosted anywhere — a temp `.mpd` (or, for the Rust
/// engine, the parsed segment plan). No local server relays media bytes.
/// Encrypted manifests (MQA / HiRes Master / Atmos) are **not** decryptable
/// here and fail with a clear error rather than fake playback — matching the
/// project's "no fake transport" rule. This is the tradeoff of the
/// no-partner-SDK path the user explicitly accepted.
///
/// Tidal rotates the web client credentials; update [clientId]/[clientSecret]
/// if auth starts returning `invalid_client`.
///
/// Parses a TIDAL home-feed JSON body off the UI thread. Top-level so it can
/// run in [compute]: home-feed payloads are large (dozens of sections,
/// hundreds of nested items) and both `jsonDecode` and model construction
/// would otherwise block the UI thread for hundreds of milliseconds.
TidalHomeFeed parseTidalHomeFeedBody(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return TidalHomeFeed.empty;
  return TidalService._parseHomeFeed(decoded);
}

/// Batch variant of [parseTidalHomeFeedBody] so a single isolate can parse
/// several payloads (used by the v1 fallback, which fetches 3 pages).
List<TidalHomeFeed> parseTidalHomeFeedBodies(List<String> bodies) {
  return [for (final body in bodies) parseTidalHomeFeedBody(body)];
}

class TidalService implements NetworkSourceService {
  TidalService._({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    TidalTokenStore? tokenStore,
    Future<void> Function(NetworkServerEntity server, String token)?
    persistToken,
    Future<bool> Function(Uri)? urlOpener,
    Duration dashSegmentHeaderTimeout = const Duration(seconds: 15),
    Duration dashSegmentIdleTimeout = const Duration(seconds: 20),
    int dashSegmentAttempts = 3,
    Duration resolvedStreamTtl = const Duration(minutes: 30),
    Duration retryDeadline = const Duration(seconds: 75),
    Duration streamResolveTimeout = defaultStreamResolveTimeout,
    Duration resolveFailureTtl = defaultResolveFailureTtl,
    int resolveTimeoutThreshold = defaultResolveTimeoutThreshold,
    Duration resolveBreakerCooldown = defaultResolveBreakerCooldown,
  }) : _client = client ?? http.Client(),
       _songRepository = songRepository,
       _networkCache = networkCache,
       _tokenStore = tokenStore,
       _persistToken = persistToken ?? _persistTokenToDatabase,
       _urlOpener = urlOpener ?? _defaultOpenUrl,
       _dashSegmentHeaderTimeout = dashSegmentHeaderTimeout,
       _dashSegmentIdleTimeout = dashSegmentIdleTimeout,
       _dashSegmentAttempts = dashSegmentAttempts,
       _resolvedStreamTtl = resolvedStreamTtl,
       _retryDeadline = retryDeadline,
       _streamResolveTimeout = streamResolveTimeout,
       _resolveFailureTtl = resolveFailureTtl,
       _resolveTimeoutThreshold = resolveTimeoutThreshold,
       _resolveBreakerCooldown = resolveBreakerCooldown;

  static TidalService instance = TidalService._();

  @visibleForTesting
  static TidalService create({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    TidalTokenStore? tokenStore,
    Future<void> Function(NetworkServerEntity server, String token)?
    persistToken,
    Future<bool> Function(Uri)? urlOpener,
    Duration dashSegmentHeaderTimeout = const Duration(seconds: 15),
    Duration dashSegmentIdleTimeout = const Duration(seconds: 20),
    int dashSegmentAttempts = 3,
    Duration resolvedStreamTtl = const Duration(minutes: 30),
    Duration retryDeadline = const Duration(seconds: 75),
    Duration streamResolveTimeout = defaultStreamResolveTimeout,
    Duration resolveFailureTtl = defaultResolveFailureTtl,
    int resolveTimeoutThreshold = defaultResolveTimeoutThreshold,
    Duration resolveBreakerCooldown = defaultResolveBreakerCooldown,
  }) => TidalService._(
    client: client,
    songRepository: songRepository,
    networkCache: networkCache,
    tokenStore: tokenStore,
    persistToken: persistToken,
    urlOpener: urlOpener,
    dashSegmentHeaderTimeout: dashSegmentHeaderTimeout,
    dashSegmentIdleTimeout: dashSegmentIdleTimeout,
    dashSegmentAttempts: dashSegmentAttempts,
    resolvedStreamTtl: resolvedStreamTtl,
    retryDeadline: retryDeadline,
    streamResolveTimeout: streamResolveTimeout,
    resolveFailureTtl: resolveFailureTtl,
    resolveTimeoutThreshold: resolveTimeoutThreshold,
    resolveBreakerCooldown: resolveBreakerCooldown,
  );

  // ponytail: Tidal desktop/TV app OAuth2 client credentials, scraped from the
  // app and published by the RE community (EbbLabs/python-tidal). NOT an official
  // API key; Tidal rotates these at will. If auth starts returning
  // `invalid_client`, pull a fresh client_id/client_secret pair from the same
  // source.
  /// Hi-Res Lossless profile (Android Automotive HiRes): yields 24-bit DASH FLAC.
  static const String hiResClientId = 'fX2JxdmntZWK0ixT';
  static const String hiResClientSecret =
      '1Nn9AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg=';

  /// Bit-Perfect Lossless profile (Android Automotive_new2): yields unencrypted
  /// 16-bit / 44.1 kHz BTS FLAC for all standard CD catalog tracks.
  static const String losslessClientId = '4N3n6Q1x95LL5K7p';
  static const String losslessClientSecret =
      'oKOXfJW371cX6xaZ0PyhgGNBdNLlBZd4AKKYougMjik=';

  /// Default client ID retained for compatibility with existing tests and device-code login.
  static const String clientId = hiResClientId;
  static const String clientSecret = hiResClientSecret;
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

  /// Timeout for the `playbackinfopostpaywall` resolve call.
  ///
  /// TIDAL sometimes accepts a connection and never answers. The general API
  /// timeout (20s) turned that into 20s of dead air per resolver, doubled by
  /// the cache-then-play fallback. Resolution metadata is cheap and small, so
  /// abandoning a silent tier after 8s is safe; segment/media downloads keep
  /// their own much longer budgets.
  static const Duration defaultStreamResolveTimeout = Duration(seconds: 8);

  /// How long a failed resolution for one track is remembered so both the
  /// direct-descriptor and the `ensureLocal` fallback fail fast instead of
  /// each paying for the same hung TIDAL endpoint.
  static const Duration defaultResolveFailureTtl = Duration(seconds: 30);

  /// Consecutive resolve timeouts (any track) that open the circuit breaker.
  static const int defaultResolveTimeoutThreshold = 3;

  /// How long the breaker refuses new resolutions before a half-open probe.
  static const Duration defaultResolveBreakerCooldown = Duration(seconds: 30);

  final http.Client _client;
  SongRepository? _songRepository;
  NetworkCacheService? _networkCache;
  TidalTokenStore? _tokenStore;
  final Future<void> Function(NetworkServerEntity server, String token)
  _persistToken;
  final Future<bool> Function(Uri) _urlOpener;
  final Map<String, TidalStreamResolution> _resolvedStreams = {};
  final Map<String, Set<void Function()>> _activeDownloads = {};
  final Map<String, Future<String>> _downloadInFlight = {};

  /// Temp `.mpd` files handed to the playback engines for DASH tracks.
  DashManifestStore? _dashManifestStore;

  DashManifestStore get _dashManifests =>
      _dashManifestStore ??= DashManifestStore();

  @visibleForTesting
  void useDashManifestStoreForTesting(DashManifestStore store) {
    _dashManifestStore = store;
  }

  @visibleForTesting
  DashManifestStore get dashManifestStoreForTesting => _dashManifests;

  /// Resilient DASH fetch policy (see [_fetchDashBytesWithRetry]): response
  /// headers must arrive within [_dashSegmentHeaderTimeout], the body may
  /// stall for at most [_dashSegmentIdleTimeout] between chunks (a
  /// slow-but-progressing transfer is never killed mid-flight), and a failed
  /// request is retried up to [_dashSegmentAttempts] times before the track
  /// download gives up. Overridable in tests via [create].
  final Duration _dashSegmentHeaderTimeout;
  final Duration _dashSegmentIdleTimeout;
  final int _dashSegmentAttempts;

  /// Base delay between DASH fetch attempts (doubles each retry).
  static const Duration _dashSegmentRetryBaseDelay = Duration(
    milliseconds: 400,
  );

  /// How long a resolved stream (CDN url / DASH manifest) may be reused.
  ///
  /// TIDAL signs stream URLs with a limited lifetime. Reusing a resolution
  /// avoids the duplicate `playbackinfopostpaywall` call made when playback
  /// starts, but must not outlive the signed URL. Thirty minutes keeps a
  /// comfortable margin while still serving replays and descriptor passes.
  /// Overridable in tests via [create].
  final Duration _resolvedStreamTtl;

  /// Total wall-clock budget for one logical API call including all 429
  /// retries. Without this, four attempts with a 120s `Retry-After` could
  /// block the caller for roughly six minutes before the UI sees an error.
  /// Overridable in tests via [create].
  final Duration _retryDeadline;

  /// Per-attempt timeout for the stream-resolution metadata call. Overridable
  /// in tests via [create] so a hung endpoint is simulated in milliseconds.
  final Duration _streamResolveTimeout;

  /// Short-TTL negative cache: track id → the hang that blocked it.
  final Map<String, _ResolveFailure> _resolveFailures = {};
  final Duration _resolveFailureTtl;
  final int _resolveTimeoutThreshold;
  final Duration _resolveBreakerCooldown;

  /// Consecutive resolution timeouts with no success in between.
  int _consecutiveResolveTimeouts = 0;

  /// Non-null while the resolve breaker is open (or half-open, once the
  /// cooldown has elapsed — a single probe is then admitted).
  DateTime? _resolveBreakerOpenedAt;
  bool _resolveBreakerProbeInFlight = false;

  /// Max entries for in-memory caches before oldest-first eviction.
  /// Prevents unbounded growth during long listening sessions.
  static const int _maxCacheEntries = 200;

  /// Evicts oldest entries if [map] exceeds [_maxCacheEntries].
  /// Maps preserve insertion order, so removing from the front evicts oldest.
  static void _evictOldestIfNeeded(Map<String, dynamic> map) {
    if (map.length <= _maxCacheEntries) return;
    final toRemove = map.length - _maxCacheEntries;
    final keys = map.keys.take(toRemove).toList();
    for (final key in keys) {
      map.remove(key);
    }
  }

  @visibleForTesting
  Map<String, Set<void Function()>> get activeDownloadsForTesting =>
      _activeDownloads;

  @visibleForTesting
  Map<String, Future<String>> get downloadInFlightForTesting =>
      _downloadInFlight;

  /// Bumped every time a track's stream finishes resolving.
  ///
  /// The resolve path itself is untouched — this is a read-only signal so
  /// UI showing per-track stream details (codec/resolution badge) can
  /// re-read [getResolvedStream] and display the *actual* stream instead
  /// of the catalog tag. Pure in-memory counter; zero playback latency.
  final ValueNotifier<int> streamResolutionVersion = ValueNotifier(0);

  /// Catalog-known max quality tier per TIDAL track id (e.g. 'LOSSLESS').
  ///
  /// Populated from catalog tags in [makeEphemeralSong] (static, so this is
  /// static too). Lets [_resolveStreamable] start its quality-tier cascade
  /// at the right tier instead of wasting `playbackinfo` API calls on
  /// higher tiers the track can never satisfy — CD-only ("Lossless") tracks
  /// otherwise pay two doomed round-trips on every cold start. Tracks
  /// without an entry fall back to the full cascade.
  static final Map<String, String> _tierStartHintByTrackId = {};

  /// Whether a track is tagged with DOLBY_ATMOS in the catalog.
  static final Map<String, bool> _hasAtmosTagByTrackId = {};

  /// Check whether a track is tagged as Dolby Atmos in the catalog.
  static bool hasAtmosTag(String trackId) =>
      _hasAtmosTagByTrackId[trackId] ?? false;

  /// Set the Dolby Atmos tag hint for testing.
  @visibleForTesting
  static void setAtmosTagHint(String trackId, bool hasAtmos) {
    _hasAtmosTagByTrackId[trackId] = hasAtmos;
  }

  /// Track title cached by trackId for logging and diagnostics.
  static final Map<String, String> _trackTitleByTrackId = {};

  /// Record a track's title so resolution logs can display the human-readable
  /// name instead of just the remote ID.
  static void recordTrackTitle(String trackId, String title) {
    if (title.isNotEmpty) {
      _trackTitleByTrackId[trackId] = title;
      _evictOldestIfNeeded(_trackTitleByTrackId);
    }
  }

  @visibleForTesting
  static void clearTrackTitlesForTesting() {
    _trackTitleByTrackId.clear();
  }

  SongRepository get _repo => _songRepository ??= SongRepository();
  NetworkCacheService get _cache => _networkCache ??= NetworkCacheService();
  TidalTokenStore get _tokens => _tokenStore ??= TidalTokenStore();

  static Future<void> _persistTokenToDatabase(
    NetworkServerEntity server,
    String token,
  ) async {
    await Database.instance.writeTxn(() async {
      final stored = await Database.networkServers.get(server.id);
      if (stored != null) {
        stored.token = token;
        await Database.networkServers.put(stored);
      }
    });
  }

  /// Forget the refresh token in secure storage for a removed/signed-out server.
  Future<void> forgetToken(int serverId) {
    _refreshTokenCache.remove(serverId);
    _profileCreds.remove(serverId);
    return _tokens.delete(serverId).timeout(_secureStorageTimeout);
  }

  /// Retrieve cached stream resolution (sampleRate, bitDepth, quality, codec) for a track.
  TidalStreamResolution? getResolvedStream(String trackId) =>
      _resolvedStreams[trackId];

  /// Evict a resolved stream from memory and delete any temporary DASH manifest.
  void clearResolution(String trackId) {
    _resolvedStreams.remove(trackId);
    unawaited(_dashManifests.evict(trackId));
    streamResolutionVersion.value++;
  }

  /// Evict all resolved streams from memory and delete all temporary DASH manifests.
  void clearAllResolutions() {
    _resolvedStreams.clear();
    unawaited(_dashManifests.evictAll());
    streamResolutionVersion.value++;
  }

  /// Uppercase display label for a track's resolved codec ("FLAC", "AAC",
  /// ...), or null when the track hasn't resolved (yet) or the codec is
  /// unknown. Pure in-memory lookup.
  String? resolvedCodecLabel(String? trackId) {
    final codec = trackId == null ? null : _resolvedStreams[trackId]?.codec;
    if (codec == null || codec.isEmpty) return null;
    return codec.toUpperCase();
  }

  /// A resolved stream that is still safe to reuse for [trackId], or null.
  ///
  /// Entries expire with [_resolvedStreamTtl] because TIDAL signs CDN URLs
  /// with a limited lifetime. They are also invalidated when the catalog
  /// quality hint for the track changes: the hint controls which tier the
  /// resolution cascade starts at, so a cached LOSSLESS stream must not be
  /// served after the catalog starts advertising HI_RES (or vice versa).
  TidalStreamResolution? _reusableResolution(
    String trackId, {
    bool? allowDolbyAtmos,
  }) {
    final cached = _resolvedStreams[trackId];
    if (cached == null) return null;

    // Bit-Perfect USB DAC mode (allowDolbyAtmos == false):
    // Never reuse an Atmos resolution; evict it and re-resolve to Hi-Res Lossless Stereo.
    if (allowDolbyAtmos == false && cached.isDolbyAtmos) {
      _resolvedStreams.remove(trackId);
      unawaited(_dashManifests.evict(trackId));
      return null;
    }
    // Dolby Atmos mode enabled (allowDolbyAtmos == true):
    // If track has Atmos tag but cached stream is Stereo, re-resolve to Atmos.
    if (allowDolbyAtmos == true &&
        (_hasAtmosTagByTrackId[trackId] ?? false) &&
        !cached.isDolbyAtmos) {
      _resolvedStreams.remove(trackId);
      unawaited(_dashManifests.evict(trackId));
      return null;
    }

    final resolvedAt = cached.resolvedAt;
    if (resolvedAt == null) return null;
    final age = DateTime.now().difference(resolvedAt);
    if (age.isNegative || age >= _resolvedStreamTtl) {
      _resolvedStreams.remove(trackId);
      // The signed URLs (and the DASH manifest that embeds them) are dead;
      // drop the temp manifest with the resolution.
      unawaited(_dashManifests.evict(trackId));
      return null;
    }

    final currentHint = _tierStartHintByTrackId[trackId];
    if (currentHint != null &&
        cached.tierHint != null &&
        currentHint != cached.tierHint) {
      _resolvedStreams.remove(trackId);
      unawaited(_dashManifests.evict(trackId));
      return null;
    }
    return cached;
  }

  @visibleForTesting
  Duration get streamResolveTimeoutForTesting => _streamResolveTimeout;

  @visibleForTesting
  int get resolutionFailureCountForTesting => _resolveFailures.length;

  @visibleForTesting
  ({Duration header, Duration idle}) get dashSegmentTimeoutsForTesting =>
      (header: _dashSegmentHeaderTimeout, idle: _dashSegmentIdleTimeout);

  /// Faithful reproduction of the failure record: the same typed error is
  /// rethrown so callers cannot tell a shared failure from a fresh hang
  /// except by how fast it arrives.
  void _throwIfRecentResolveFailure(String trackId) {
    final failure = _resolveFailures[trackId];
    if (failure == null) return;
    final age = DateTime.now().difference(failure.at);
    if (age.isNegative || age >= _resolveFailureTtl) {
      _resolveFailures.remove(trackId);
      return;
    }
    devLog(
      '[Tidal] resolve($trackId) hung ${age.inMilliseconds}ms ago; '
      'failing fast for the rest of the ${_resolveFailureTtl.inSeconds}s window',
    );
    throw failure.error;
  }

  /// Admits one resolution through the timeout breaker.
  ///
  /// Returns true when this call is the single half-open probe, so the caller
  /// can release the probe slot in a `finally`.
  bool _admitResolve() {
    final openedAt = _resolveBreakerOpenedAt;
    if (openedAt == null) return false;
    final elapsed = DateTime.now().difference(openedAt);
    if (elapsed.isNegative || elapsed < _resolveBreakerCooldown) {
      final remaining = _resolveBreakerCooldown - elapsed;
      throw TidalUnavailableException(remaining);
    }
    // Cooldown elapsed: half-open. Exactly one probe may touch the network.
    if (_resolveBreakerProbeInFlight) {
      throw TidalUnavailableException();
    }
    _resolveBreakerProbeInFlight = true;
    return true;
  }

  void _onResolveSuccess() {
    _consecutiveResolveTimeouts = 0;
    _resolveBreakerOpenedAt = null;
  }

  /// Records a silent hang: negative-cache the track and advance the breaker.
  ///
  /// Permanent errors (404/entitlement/429) deliberately do not reach this
  /// method: they are not a dead endpoint, so they must not masquerade as one.
  void _onResolveTimeout(String trackId, Object cause) {
    _resolveFailures[trackId] = _ResolveFailure(
      TidalUnavailableException(),
      DateTime.now(),
    );
    _evictOldestIfNeeded(_resolveFailures);

    _consecutiveResolveTimeouts++;
    if (_resolveBreakerOpenedAt != null ||
        _consecutiveResolveTimeouts >= _resolveTimeoutThreshold) {
      _resolveBreakerOpenedAt = DateTime.now();
      devLog(
        '[Tidal] resolve breaker OPEN after '
        '$_consecutiveResolveTimeouts consecutive timeout(s); '
        'failing fast for ${_resolveBreakerCooldown.inSeconds}s (last: $cause)',
      );
    }
  }

  /// Cancel in-flight download for a specific track.
  void cancelActiveDownload(String remoteId) {
    final callbacks = _activeDownloads.remove(remoteId);
    if (callbacks != null) {
      for (final cancel in callbacks) {
        cancel();
      }
    }
    unawaited(_dashManifests.evict(remoteId));
  }

  /// Cancel all in-flight downloads (e.g. when changing songs immediately).
  void cancelAllDownloads() {
    for (final callbacks in _activeDownloads.values.toList()) {
      for (final cancel in callbacks) {
        cancel();
      }
    }
    _activeDownloads.clear();
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
    // auth.tidal.com can be slow from some networks: retry the initial
    // request instead of failing the whole sign-in on one timeout.
    Map<String, dynamic>? dev;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        dev = await _postForm('$_authBase/device_authorization', {
          'client_id': clientId,
          'scope': _scope,
        }).timeout(const Duration(seconds: 30));
        break;
      } on TimeoutException {
        devLog(
          '[Tidal] device_authorization attempt ${attempt + 1}/3 timed out',
        );
        if (attempt == 2) rethrow;
      }
    }
    final deviceCode = dev!['deviceCode'] as String?;
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
      // One flaky poll must not kill the whole sign-in: keep polling.
      Map<String, dynamic> tok;
      try {
        tok = await _postForm('$_authBase/token', {
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': deviceCode,
          'scope': _scope,
        }, raw: true);
      } on TimeoutException {
        devLog('[Tidal] token poll timed out, continuing...');
        continue;
      }

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

  final Map<int, Future<_TidalCreds>> _refreshInFlight = {};

  /// In-memory cache of valid credentials per server ID and client profile.
  final Map<int, Map<TidalClientProfile, _TidalCreds>> _profileCreds = {};

  /// In-flight profile-specific refresh operations (keyed by '$serverId:${profile.name}').
  final Map<String, Future<_TidalCreds>> _profileRefreshInFlight = {};

  /// Bound for secure-storage (platform channel) reads/writes in the token
  /// path. The platform channel has no built-in timeout; without this bound a
  /// wedged keystore call would hang the caller forever — and, via
  /// [_refreshInFlight], every TIDAL API call for the rest of the session
  /// (infinite loading spinners that never resolve and never error).
  static const Duration _secureStorageTimeout = Duration(seconds: 15);

  /// In-memory copy of secure-storage refresh tokens, keyed by server id.
  /// Populated on first read/write so the hot API path doesn't pay a
  /// platform-channel round trip per call — shrinking the window where a
  /// wedged keystore can stall requests.
  final Map<int, String> _refreshTokenCache = {};

  /// Read the refresh token, preferring the in-memory copy. Throws
  /// [TimeoutException] if the keystore doesn't answer in time — callers
  /// must NOT swallow that as "no session".
  Future<String?> _readRefreshToken(int serverId) async {
    final cached = _refreshTokenCache[serverId];
    if (cached != null) return cached;
    final value = await _tokens.read(serverId).timeout(_secureStorageTimeout);
    if (value != null && value.isNotEmpty) {
      _refreshTokenCache[serverId] = value;
    }
    return value;
  }

  /// Persist the refresh token to secure storage and the in-memory copy.
  /// Throws [TimeoutException] if the keystore doesn't answer in time.
  Future<void> _writeRefreshToken(int serverId, String token) async {
    await _tokens.write(serverId, token).timeout(_secureStorageTimeout);
    _refreshTokenCache[serverId] = token;
  }

  @visibleForTesting
  Map<int, Future<TidalCreds>> get refreshInFlightForTesting =>
      _refreshInFlight;

  @visibleForTesting
  Future<TidalCreds> ensureValidTokenForTesting(
    NetworkServerEntity server, {
    TidalClientProfile? profile,
  }) => _ensureValidToken(server, profile: profile);

  Future<_TidalCreds> _ensureValidToken(
    NetworkServerEntity server, {
    TidalClientProfile? profile,
  }) async {
    if (profile == null) {
      return _ensureValidBaseToken(server);
    }

    final profileMap = _profileCreds.putIfAbsent(server.id, () => {});
    final cached = profileMap[profile];
    if (cached != null && !cached.isNearExpiry) {
      return cached;
    }

    final baseCreds = _creds(server.token);
    if (cached == null && baseCreds != null && !baseCreds.isNearExpiry) {
      // In tests/mocks where accessToken is not a dotted JWT:
      if (!baseCreds.accessToken.contains('.')) {
        profileMap[profile] = baseCreds;
        return baseCreds;
      }
      final claims = _parseJwtClaims(baseCreds.accessToken);
      final isMatching = profile == TidalClientProfile.hiRes
          ? (claims.cid == 13319)
          : (claims.cid == 6432 || claims.cid == 602440243);
      if (isMatching) {
        profileMap[profile] = baseCreds;
        return baseCreds;
      }
    }

    final inFlightKey = '${server.id}:${profile.name}';
    final inFlight = _profileRefreshInFlight[inFlightKey];
    if (inFlight != null) {
      return inFlight;
    }

    try {
      final future = _doRefreshForProfile(
        server,
        profile,
      ).timeout(const Duration(seconds: 5));
      _profileRefreshInFlight[inFlightKey] = future;
      final refreshed = await future;
      profileMap[profile] = refreshed;
      return refreshed;
    } catch (e) {
      devLog(
        '[Tidal] Dual-client refresh for ${profile.name} failed: $e, falling back to base token',
      );
      return _ensureValidBaseToken(server);
    } finally {
      _profileRefreshInFlight.remove(inFlightKey);
    }
  }

  Future<_TidalCreds> _doRefreshForProfile(
    NetworkServerEntity server,
    TidalClientProfile profile,
  ) async {
    var refresh = _creds(server.token)?.refreshToken;
    if ((refresh == null || refresh.isEmpty) && server.id > 0) {
      try {
        refresh = await _readRefreshToken(server.id);
      } on TimeoutException {
        rethrow;
      } catch (e) {
        devLog('Tidal secure storage read failed: $e');
      }
    }
    if (refresh == null || refresh.isEmpty) {
      final otherProfile = profile == TidalClientProfile.hiRes
          ? TidalClientProfile.lossless
          : TidalClientProfile.hiRes;
      refresh = _profileCreds[server.id]?[otherProfile]?.refreshToken;
    }
    if (refresh == null || refresh.isEmpty) {
      throw TidalException('Tidal session expired. Please sign in again.');
    }

    final targetClientId = profile == TidalClientProfile.hiRes
        ? hiResClientId
        : losslessClientId;
    final targetClientSecret = profile == TidalClientProfile.hiRes
        ? hiResClientSecret
        : losslessClientSecret;

    final tok = await _postForm('$_authBase/token', {
      'client_id': targetClientId,
      if (targetClientSecret.isNotEmpty) 'client_secret': targetClientSecret,
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    final access = tok['access_token'] as String?;
    if (access == null) {
      throw TidalException('Tidal token refresh failed.');
    }
    final newRefresh = (tok['refresh_token'] as String?) ?? refresh;
    final updated = _TidalCreds(
      accessToken: access,
      refreshToken: newRefresh,
      userId: _creds(server.token)?.userId,
      countryCode: _creds(server.token)?.countryCode ?? 'US',
      expiresAtMs: DateTime.now()
          .add(Duration(seconds: (tok['expires_in'] as num?)?.toInt() ?? 3600))
          .millisecondsSinceEpoch,
    );

    if (server.id > 0 && newRefresh.isNotEmpty) {
      try {
        await _writeRefreshToken(server.id, newRefresh);
      } catch (e) {
        devLog(
          'Tidal secure storage write failed during dual-client refresh: $e',
        );
      }
    }

    return updated;
  }

  Future<_TidalCreds> _ensureValidBaseToken(NetworkServerEntity server) async {
    final inFlight = _refreshInFlight[server.id];
    if (inFlight != null) {
      return inFlight;
    }
    var creds = _creds(server.token);
    if (creds == null) {
      throw TidalException('No Tidal sign-in. Tap "Sign in with Tidal".');
    }

    final nearExpiry =
        creds.expiresAtMs == null ||
        DateTime.now().millisecondsSinceEpoch > creds.expiresAtMs! - 60000;
    if (nearExpiry) {
      return _refresh(server, creds);
    }

    if (server.id > 0) {
      if (creds.refreshToken != null && creds.refreshToken!.isNotEmpty) {
        await migrateServerToken(server);
      } else {
        String? secureRefresh;
        try {
          secureRefresh = await _readRefreshToken(server.id);
        } on TimeoutException {
          // Don't mask a wedged keystore as "no session" — surface it so the
          // caller fails fast instead of hanging or misreporting.
          rethrow;
        } catch (e) {
          devLog('Tidal secure storage read failed: $e');
        }
        if (secureRefresh != null) {
          creds = creds.copyWith(refreshToken: secureRefresh);
        }
      }
    }

    return creds;
  }

  Future<_TidalCreds> _refresh(
    NetworkServerEntity server,
    _TidalCreds old,
  ) async {
    final inFlight = _refreshInFlight[server.id];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _doRefresh(server, old);
    _refreshInFlight[server.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshInFlight[server.id], future)) {
        _refreshInFlight.remove(server.id);
      }
    }
  }

  Future<_TidalCreds> _doRefresh(
    NetworkServerEntity server,
    _TidalCreds old,
  ) async {
    var refresh = old.refreshToken;
    if ((refresh == null || refresh.isEmpty) && server.id > 0) {
      try {
        refresh = await _readRefreshToken(server.id);
      } on TimeoutException {
        rethrow;
      } catch (e) {
        devLog('Tidal secure storage read failed: $e');
      }
    }
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

  Future<void> _stripRefreshTokenFromDatabase(
    NetworkServerEntity server,
    _TidalCreds creds,
  ) async {
    final stripped = jsonEncode({
      'access_token': creds.accessToken,
      'user_id': creds.userId,
      'country_code': creds.countryCode,
      'expires_at_ms': creds.expiresAtMs,
    });
    server.token = stripped;
    try {
      await _persistToken(server, stripped);
    } catch (e) {
      devLog('Tidal strip token persist failed: $e');
    }
  }

  Future<void> _persist(NetworkServerEntity server, _TidalCreds creds) async {
    if (creds.refreshToken != null &&
        creds.refreshToken!.isNotEmpty &&
        server.id > 0) {
      try {
        await _writeRefreshToken(server.id, creds.refreshToken!);
      } on TimeoutException {
        // The fresh token pair may not be persisted; failing fast is safer
        // than proceeding with a session that can't survive the next refresh.
        devLog('Tidal token secure persist timed out');
        rethrow;
      } catch (e) {
        devLog('Tidal token secure persist failed: $e');
      }
    }
    final token = jsonEncode({
      'access_token': creds.accessToken,
      'user_id': creds.userId,
      'country_code': creds.countryCode,
      'expires_at_ms': creds.expiresAtMs,
    });
    server.token = token;
    try {
      await _persistToken(server, token);
    } catch (e) {
      devLog('Tidal token persist failed: $e');
    }
  }

  /// Migrate a legacy plaintext refresh token to secure storage and strip
  /// it from [server.token] and the database.
  Future<void> migrateServerToken(
    NetworkServerEntity server, {
    TidalTokenStore? tokenStore,
  }) async {
    final store = tokenStore ?? _tokens;
    final creds = _creds(server.token);
    if (creds == null) return;

    final legacyRefresh = creds.refreshToken;
    if (server.id > 0) {
      String? existingSecure;
      try {
        existingSecure = await store
            .read(server.id)
            .timeout(_secureStorageTimeout);
      } catch (_) {}

      // Only strip the DB token once secure storage is CONFIRMED to hold it —
      // otherwise a failed/timed-out write would lose the refresh token
      // entirely and force a re-login.
      if ((existingSecure == null || existingSecure.isEmpty) &&
          legacyRefresh != null &&
          legacyRefresh.isNotEmpty) {
        try {
          await store
              .write(server.id, legacyRefresh)
              .timeout(_secureStorageTimeout);
          existingSecure = legacyRefresh;
        } catch (_) {}
      }

      if (legacyRefresh != null &&
          legacyRefresh.isNotEmpty &&
          existingSecure != null &&
          existingSecure.isNotEmpty) {
        await _stripRefreshTokenFromDatabase(server, creds);
      }
    }
  }

  // --- JSON API ----------------------------------------------------------

  // Global API rate limiter: smooths request bursts so we don't trip TIDAL's
  // server-side rate limiter. Every API call awaits [_throttle] first, which
  // enforces a minimum gap between requests (serialized via [_throttleGate]
  // so concurrent callers can't all slip through at once).
  DateTime _lastApiCall = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _throttleGate = Future.value();
  static const _minApiGap = Duration(milliseconds: 100);

  Future<void> _throttle() {
    final next = _throttleGate.then((_) async {
      final elapsed = DateTime.now().difference(_lastApiCall);
      if (elapsed < _minApiGap) {
        await Future.delayed(_minApiGap - elapsed);
      }
      _lastApiCall = DateTime.now();
    });
    // Don't let one caller's error poison the gate for everyone else.
    _throttleGate = next.catchError((_) {});
    return next;
  }

  /// Parses a `Retry-After` header value (delta-seconds or HTTP date).
  /// Returns [Duration.zero] when absent or unparsable. Capped at 120s so a
  /// rogue header can't stall the app for minutes.
  Duration _parseRetryAfter(String? value) {
    if (value == null) return Duration.zero;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(0, 120));
    }
    try {
      final diff = HttpDate.parse(
        value.trim(),
      ).difference(DateTime.now().toUtc());
      if (diff.isNegative) return Duration.zero;
      return diff > const Duration(seconds: 120)
          ? const Duration(seconds: 120)
          : diff;
    } catch (_) {
      return Duration.zero;
    }
  }

  /// Sends an HTTP request, transparently retrying on 429 (rate limit).
  /// Honors the server's `Retry-After` header when present, otherwise backs
  /// off exponentially (1s, 2s, 4s). After [maxAttempts] the 429 response is
  /// returned as-is so the caller can throw a proper exception.
  ///
  /// The retry loop is bounded by [_retryDeadline] across all attempts. A
  /// `Retry-After: 120` therefore no longer parks a user-facing call for
  /// minutes: once the next backoff would exceed the remaining budget, the
  /// 429 response is returned immediately and the caller surfaces the
  /// rate-limit state.
  Future<http.Response> _with429Retry(
    String label,
    Future<http.Response> Function() send, {
    int maxAttempts = 4, // 1 initial + 3 retries
  }) async {
    final deadline = DateTime.now().add(_retryDeadline);
    http.Response? lastResponse;
    for (var attempt = 0; ; attempt++) {
      // A previous attempt may have consumed the whole budget (slow HTTP).
      if (attempt > 0 && !DateTime.now().isBefore(deadline)) {
        devLog(
          '[Tidal] 429 $label — retry deadline (${_retryDeadline.inSeconds}s) '
          'reached, giving up',
        );
        return lastResponse!;
      }
      final response = await send();
      lastResponse = response;
      if (response.statusCode != 429) return response;
      if (attempt + 1 >= maxAttempts) return response;
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      final backoff = Duration(seconds: 1 << attempt);
      final delay = retryAfter > backoff ? retryAfter : backoff;
      if (!DateTime.now().add(delay).isBefore(deadline)) {
        devLog(
          '[Tidal] 429 $label — next backoff ${delay.inSeconds}s exceeds '
          'retry deadline (${_retryDeadline.inSeconds}s), giving up',
        );
        return response;
      }
      devLog(
        '[Tidal] 429 $label — backing off ${delay.inSeconds}s '
        '(attempt ${attempt + 1}/$maxAttempts)',
      );
      await Future.delayed(delay);
    }
  }

  /// Raw-body variant of [_apiGet]: returns the response body as a [String]
  /// without JSON-decoding it, so large payloads can be parsed on a
  /// background isolate via [compute] instead of blocking the UI thread.
  Future<String> _apiGetRaw(
    NetworkServerEntity server,
    String path, {
    Map<String, String>? query,
    bool retry = true,
    Duration? timeout,
    TidalClientProfile? profile,
  }) async {
    final creds = await _ensureValidToken(server, profile: profile);
    final uri = Uri.parse(
      '$_apiBase$path',
    ).replace(queryParameters: {'countryCode': creds.countryCode, ...?query});
    await _throttle();
    final http.Response response;
    try {
      response = await _with429Retry(
        'GET $path',
        () => _client
            .get(
              uri,
              headers: {
                'Authorization': 'Bearer ${creds.accessToken}',
                'Accept': 'application/json',
              },
            )
            .timeout(timeout ?? const Duration(seconds: 20)),
      );
    } on TimeoutException catch (e) {
      // Only the callers that asked for a tighter budget (stream resolution)
      // get the typed marker: a keystore/token timeout elsewhere must not be
      // mistaken for a dead TIDAL endpoint.
      if (timeout == null) rethrow;
      throw _TidalHttpTimeout(e);
    }
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      if (profile != null) {
        await _doRefreshForProfile(server, profile);
      } else {
        await _refresh(server, creds);
      }
      return _apiGetRaw(
        server,
        path,
        query: query,
        retry: false,
        timeout: timeout,
        profile: profile,
      );
    }
    if (response.statusCode == 429) {
      throw TidalRateLimitedException(
        _parseRetryAfter(response.headers['retry-after']).inSeconds,
      );
    }
    if (response.statusCode != 200) {
      throw TidalHttpException(response.statusCode, path);
    }
    return response.body;
  }

  Future<Map<String, dynamic>> _apiGet(
    NetworkServerEntity server,
    String path, {
    Map<String, String>? query,
    bool retry = true,
    Duration? timeout,
    TidalClientProfile? profile,
  }) async {
    final body = await _apiGetRaw(
      server,
      path,
      query: query,
      retry: retry,
      timeout: timeout,
      profile: profile,
    );
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postForm(
    String url,
    Map<String, String> fields, {
    bool raw = false,
  }) async {
    await _throttle();
    final response = await _with429Retry(
      'POST $url',
      () => _client
          .post(Uri.parse(url), body: fields)
          .timeout(const Duration(seconds: 20)),
    );
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

  /// Raw-body variant of [_apiV2Get]: returns the response body as a [String]
  /// without JSON-decoding it, so large payloads can be parsed on a
  /// background isolate via [compute] instead of blocking the UI thread.
  Future<String> _apiV2GetRaw(
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
    await _throttle();
    final response = await _with429Retry(
      'GET v2$path',
      () => _client
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer ${creds.accessToken}',
              'Accept': 'application/json',
              'x-tidal-client-version': '2026.9.15',
            },
          )
          .timeout(const Duration(seconds: 20)),
    );
    if (response.statusCode == 401 && retry && creds.refreshToken != null) {
      await _refresh(server, creds);
      return _apiV2GetRaw(server, path, query: query, retry: false);
    }
    if (response.statusCode == 429) {
      throw TidalRateLimitedException(
        _parseRetryAfter(response.headers['retry-after']).inSeconds,
      );
    }
    if (response.statusCode != 200) {
      throw TidalException('HTTP ${response.statusCode} for $path');
    }
    return response.body;
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
    await _throttle();
    final response = await _with429Retry(
      'POST $url',
      () => _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${creds.accessToken}',
              ...?headers,
            },
            body: fields,
          )
          .timeout(const Duration(seconds: 20)),
    );
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
    await _throttle();
    final response = await _with429Retry(
      'POST $url',
      () => _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${creds.accessToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20)),
    );
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
    await _throttle();
    final response = await _with429Retry(
      'DELETE $url',
      () => _client
          .delete(
            uri,
            headers: {'Authorization': 'Bearer ${creds.accessToken}'},
          )
          .timeout(const Duration(seconds: 20)),
    );
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
    await _throttle();
    final response = await _with429Retry(
      'GET /playlists/$playlistId',
      () => _client
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer ${creds.accessToken}',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20)),
    );
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

  /// Joins all artist names with ', ' so collab tracks show every artist
  /// instead of just the first. Returns null when there are no usable names
  /// so callers can fall back to their own default.
  static String? joinArtistNames(List<Map<String, dynamic>?>? artists) {
    if (artists == null || artists.isEmpty) return null;
    final names = artists
        .map((a) => a?['name'] as String?)
        .where((n) => n != null && n.isNotEmpty)
        .cast<String>()
        .toList();
    if (names.isEmpty) return null;
    return names.join(', ');
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

  /// Build a `resources.tidal.com` image URL for an artist profile picture.
  ///
  /// Supported square resolutions on TIDAL CDN for artist pictures are
  /// 160x160, 320x320, and 750x750.
  ///
  /// Note: 640x640 is NOT generated on TIDAL's CDN for artist pictures and
  /// returns HTTP 403 Forbidden. This helper maps requested sizes to supported
  /// resolutions (defaulting to 320 for 140dp-160dp avatars).
  static String artistPictureUrl(String pictureUuid, {int size = 320}) {
    if (pictureUuid.isEmpty) return '';
    final int effectiveSize;
    if (size <= 160) {
      effectiveSize = 160;
    } else if (size <= 320) {
      effectiveSize = 320;
    } else {
      effectiveSize = 750;
    }
    return coverUrl(pictureUuid, size: effectiveSize);
  }

  /// Upgrade a TIDAL cover URL to a larger size (e.g. 640 → 1280).
  /// Returns the original URL if it doesn't match the expected pattern.
  static String upscaleCoverUrl(String url, int size) {
    final regex = RegExp(r'/\d+x\d+\.jpg$');
    if (!regex.hasMatch(url)) return url;
    return url.replaceFirst(regex, '/${size}x$size.jpg');
  }

  /// Build a `resources.tidal.com` image URL for 3:2 landscape images (e.g. playlist `image`).
  /// Supported resolutions on Tidal CDN are 320x214, 480x320, 640x428, 750x500, 1080x720.
  static String wideCoverUrl(String coverUuid, {int width = 480}) {
    if (coverUuid.isEmpty) return '';
    final clean = coverUuid.replaceAll('-', '');
    if (clean.length < 5) return '';
    if (clean.replaceAll('0', '').isEmpty) return '';
    final String path;
    if (clean.length == 32) {
      path =
          '${clean.substring(0, 8)}/${clean.substring(8, 12)}/${clean.substring(12, 16)}/${clean.substring(16, 20)}/${clean.substring(20)}';
    } else {
      path = coverUuid.replaceAll('-', '/');
    }
    final int targetW;
    final int targetH;
    if (width <= 320) {
      targetW = 320;
      targetH = 214;
    } else if (width <= 480) {
      targetW = 480;
      targetH = 320;
    } else if (width <= 640) {
      targetW = 640;
      targetH = 428;
    } else if (width <= 750) {
      targetW = 750;
      targetH = 500;
    } else {
      targetW = 1080;
      targetH = 720;
    }
    return '$_coverHost/$path/${targetW}x$targetH.jpg';
  }

  /// Safely transform a Tidal cover URL to a different resolution (e.g. 160, 320, 640).
  /// Preserves 3:2 aspect ratios if the URL is a wide landscape image.
  /// Returns the original URL if it is not a recognized Tidal resource URL.
  static String? resizedCoverUrl(String? originalUrl, int size) {
    if (originalUrl == null || originalUrl.isEmpty) return originalUrl;
    if (!originalUrl.contains('resources.tidal.com')) return originalUrl;
    final wideMatch = RegExp(r'(\d+)x(\d+)\.jpg$').firstMatch(originalUrl);
    if (wideMatch != null) {
      final w = int.tryParse(wideMatch.group(1) ?? '') ?? 0;
      final h = int.tryParse(wideMatch.group(2) ?? '') ?? 0;
      if (w != h && w > 0 && h > 0) {
        final int targetW;
        final int targetH;
        if (size <= 160) {
          targetW = 320;
          targetH = 214;
        } else if (size <= 320) {
          targetW = 480;
          targetH = 320;
        } else if (size <= 480) {
          targetW = 640;
          targetH = 428;
        } else {
          targetW = 750;
          targetH = 500;
        }
        return originalUrl.replaceAll(
          RegExp(r'\d+x\d+\.jpg$'),
          '${targetW}x$targetH.jpg',
        );
      }
    }
    return originalUrl.replaceAll(
      RegExp(r'\d+x\d+\.jpg$'),
      '${size}x$size.jpg',
    );
  }

  /// Extracts the best available cover URL from a TIDAL playlist object.
  /// Prioritizes square imagery (`squareImage`, `squareImageUuid`, `cover`)
  /// over wide landscape imagery (`image`), ensuring CloudFront returns 200 instead of 403.
  static String? extractPlaylistCover(
    Map<String, dynamic> playlist, {
    int size = 320,
  }) {
    // 1. Square image identifiers (must be first - square dimensions work on CDN)
    final squareCover =
        playlist['squareImage'] ??
        playlist['squareImageUuid'] ??
        playlist['cover'] ??
        playlist['artworkId'] ??
        playlist['customImage'];
    if (squareCover is String && squareCover.isNotEmpty) {
      if (squareCover.startsWith('http') ||
          squareCover.startsWith('file:') ||
          squareCover.startsWith('/')) {
        return squareCover;
      }
      final url = coverUrl(squareCover, size: size);
      if (url.isNotEmpty) return url;
    }

    // 2. Handle nested images structure (Map or List)
    final rawImages = playlist['squareImages'] ?? playlist['images'];
    if (rawImages is Map) {
      final large =
          rawImages['LARGE'] ??
          rawImages['large'] ??
          rawImages['MEDIUM'] ??
          rawImages['medium'] ??
          rawImages['SMALL'] ??
          rawImages['small'];
      if (large is Map) {
        final u = large['url']?.toString();
        if (u != null && u.isNotEmpty) return u;
      } else if (large is String && large.isNotEmpty) {
        if (large.startsWith('http')) return large;
        final url = coverUrl(large, size: size);
        if (url.isNotEmpty) return url;
      }
      for (final val in rawImages.values) {
        if (val is Map &&
            val['url'] is String &&
            (val['url'] as String).isNotEmpty) {
          return val['url'] as String;
        }
      }
    } else if (rawImages is List && rawImages.isNotEmpty) {
      for (final item in rawImages) {
        if (item is Map) {
          final u = item['url']?.toString();
          if (u != null && u.isNotEmpty) return u;
        } else if (item is String && item.isNotEmpty) {
          if (item.startsWith('http')) return item;
          final url = coverUrl(item, size: size);
          if (url.isNotEmpty) return url;
        }
      }
    }

    // 3. Direct imageUrl string
    if (playlist['imageUrl'] is String &&
        (playlist['imageUrl'] as String).isNotEmpty) {
      return playlist['imageUrl'] as String;
    }

    // 4. Picture identifier
    final picture = playlist['picture'];
    if (picture is String && picture.isNotEmpty) {
      if (picture.startsWith('http')) return picture;
      final url = coverUrl(picture, size: size);
      if (url.isNotEmpty) return url;
    }

    // 5. Landscape/wide image fallback (using 3:2 aspect ratio so CDN doesn't 403)
    final wideImage = playlist['image'];
    if (wideImage is String && wideImage.isNotEmpty) {
      if (wideImage.startsWith('http') ||
          wideImage.startsWith('file:') ||
          wideImage.startsWith('/')) {
        return wideImage;
      }
      final url = wideCoverUrl(wideImage, width: size > 160 ? 640 : 480);
      if (url.isNotEmpty) return url;
    }

    return null;
  }

  // --- Lyrics -----------------------------------------------------------

  /// Fetch lyrics for [trackId] from TIDAL.
  ///
  /// Endpoint: `GET /v1/tracks/{id}/lyrics` (community-documented; it is not
  /// part of TIDAL's published API reference). It goes through [_apiGetRaw],
  /// so it inherits the Bearer token, `countryCode`, throttling and the 429
  /// retry. Lyrics are not playbackinfo, so no client-profile routing applies.
  ///
  /// A 404 means "this track has no lyrics" and returns null — it must never
  /// surface as an error. 401/403 are treated the same way: the endpoint is
  /// known to refuse tokens without the lyrics scope, and the caller falls
  /// back to lrclib instead of showing a failure. Any other failure (5xx, 429,
  /// timeout) is rethrown so the caller can decide.
  Future<TidalLyrics?> getTrackLyrics(
    NetworkServerEntity server,
    String trackId,
  ) async {
    if (trackId.isEmpty) return null;
    try {
      final body = await _apiGetRaw(server, '/tracks/$trackId/lyrics');
      if (body.trim().isEmpty) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final lyrics = TidalLyrics.fromJson(trackId, decoded);
      return lyrics.isEmpty ? null : lyrics;
    } on TidalHttpException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 401 || e.statusCode == 403) {
        devLog('[Tidal] no lyrics for $trackId (HTTP ${e.statusCode})');
        return null;
      }
      rethrow;
    }
  }

  // --- Stream ----------------------------------------------------------

  @override
  Future<({String url, Map<String, String> headers})?> streamDescriptor(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
    bool allowDolbyAtmos = false,
  }) async {
    // Invalidate stale Atmos resolution when Atmos is not allowed
    if (!allowDolbyAtmos && _resolvedStreams[remoteId]?.isDolbyAtmos == true) {
      _resolvedStreams.remove(remoteId);
      unawaited(_dashManifests.evict(remoteId));
      unawaited(_cache.evictFile(server.id, remoteId, extension: 'mp4'));
    }

    final extHint =
        (!allowDolbyAtmos &&
            (_resolvedStreams[remoteId]?.isDolbyAtmos == true ||
                _resolvedStreams[remoteId]?.ext == 'mp4'))
        ? (extension ?? 'flac')
        : (_resolvedStreams[remoteId]?.ext ?? extension ?? 'flac');

    // 1. If already cached locally, return null so playback uses the local file directly.
    try {
      final cached = await _cache.getPath(
        server.id,
        remoteId,
        extension: extHint,
      );
      if (cached != null) {
        return null;
      }
    } catch (_) {}

    // PlayerService resolves once for display metadata, then the playback
    // engine resolves again to start playback. Reuse the first resolution
    // while the signed CDN URLs are still fresh, so the second pass does not
    // issue another playback-info API request. There is no longer a local
    // session to reuse, only the resolution itself.
    final reusable = _reusableResolution(
      remoteId,
      allowDolbyAtmos: allowDolbyAtmos,
    );
    if (reusable != null) {
      return _directDescriptor(server, remoteId, reusable);
    }

    final resolved = await _resolveStreamable(
      server,
      remoteId,
      allowDolbyAtmos: allowDolbyAtmos,
    );
    if (resolved == null) return null;
    return _directDescriptor(server, remoteId, resolved);
  }

  /// Descriptor handed to the speaker engine: a CDN file URL (BTS) or a temp
  /// `.mpd` (DASH) that ExoPlayer loads itself.
  Future<({String url, Map<String, String> headers})?> _directDescriptor(
    NetworkServerEntity server,
    String remoteId,
    TidalStreamResolution resolved,
  ) async {
    final headers = _streamHeaders(resolved);

    if (!resolved.isDash) {
      // 2. BTS: the CDN file URL is ranged-GET-able; hand it over as-is.
      // Re-check the cache with the resolved extension, which can differ from
      // the song's file type (e.g. an AAC stream for a "flac" track).
      try {
        final cached = await _cache.getPath(
          server.id,
          remoteId,
          extension: resolved.ext ?? 'flac',
        );
        if (cached != null) return null;
      } catch (_) {}
      return (url: resolved.url, headers: headers);
    }

    // 3. DASH: the manifest arrives embedded in the playbackinfo response, so
    // it has to be written out before any player can use it. Strip it to the
    // single Representation the parser chose: with no proxy fallback a
    // multi-representation MPD would let ABR silently downshift while the
    // quality badge still claims the top tier.
    final dashInfo = resolved.dashInfo;
    if (dashInfo == null) {
      throw TidalException('DASH track $remoteId has no manifest.');
    }
    if (!dashManifestIsSelfContained(dashInfo)) {
      devLog(
        '[Tidal] DASH $remoteId is not directly playable: the manifest does '
        'not resolve every segment to an absolute https URL',
      );
      throw TidalException(
        'DASH manifest for $remoteId is not directly playable.',
      );
    }
    final stripped = DashManifestParser.stripToSingleRepresentation(
      dashInfo.manifestXml,
      targetRepresentationId: dashInfo.representationId,
      allowDolbyAtmos: resolved.isDolbyAtmos,
    );
    if (stripped == null) {
      throw TidalException(
        'DASH manifest for $remoteId could not be reduced to a single '
        'representation.',
      );
    }
    final manifestPath = await _dashManifests.write(
      trackId: remoteId,
      xml: stripped,
    );
    return (url: Uri.file(manifestPath).toString(), headers: headers);
  }

  /// `x-flick-*` out-of-band metadata for the Rust decoder. The speaker path
  /// drops these; the DAC path passes them through unchanged.
  Map<String, String> _streamHeaders(TidalStreamResolution resolved) => {
    if (resolved.isSampleRateExplicit)
      'x-flick-sample-rate': resolved.sampleRate.toString(),
    if (resolved.isBitDepthExplicit)
      'x-flick-bit-depth': resolved.bitDepth.toString(),
    if (resolved.ext != null && resolved.ext!.isNotEmpty)
      'x-flick-extension-hint': resolved.ext!,
  };

  /// Descriptor for the Rust engine when [trackId] resolved to DASH.
  ///
  /// The Rust engine has no MPD support, and the manifest is not hosted
  /// anywhere the engine could fetch it from. Rather than parse the manifest a
  /// second time in Rust, hand over the plan the Dart parser already produced
  /// — the init segment plus the ordered media segment URLs of the chosen
  /// Representation — as a `dash://` descriptor carrying them in the headers
  /// map. Both engines then fetch the same CDN objects, and segment ordering
  /// has a single source of truth.
  ///
  /// Returns null for non-DASH tracks and when the plan cannot be built (the
  /// caller then falls back to cache-then-play, never to a proxy).
  ({String url, Map<String, String> headers})? directDashPlan(String trackId) {
    final resolved = _reusableResolution(trackId);
    final dashInfo = resolved?.dashInfo;
    if (resolved == null || !resolved.isDash || dashInfo == null) return null;
    if (!dashManifestIsSelfContained(dashInfo)) return null;
    return (
      url: 'dash://$trackId',
      headers: {
        ..._streamHeaders(resolved),
        'x-flick-dash-init': dashInfo.initializationUrl,
        'x-flick-dash-segments': dashInfo.segmentUrls.join('\n'),
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
    final flightKey = '${server.id}_$remoteId';
    final existingFlight = _downloadInFlight[flightKey];
    if (existingFlight != null) {
      return existingFlight;
    }

    final future = _doStream(
      server,
      remoteId,
      extension: extension,
      onProgress: onProgress,
    );
    _downloadInFlight[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_downloadInFlight[flightKey], future)) {
        _downloadInFlight.remove(flightKey);
      }
    }
  }

  Future<String> _doStream(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
    void Function(double progress)? onProgress,
  }) async {
    // The cache lookup must use the extension of the *resolved* stream, not
    // the song's file type: the DASH pump downloads hi-res tracks as
    // `<hash>.mp4` while `song.fileType` stays `'flac'`. Without this, a late
    // rearm misses the cached mp4 and re-downloads the whole track (~25s).
    // Ensure we don't return an Atmos MP4 for standard local playback / download
    if (_resolvedStreams[remoteId]?.isDolbyAtmos == true) {
      _resolvedStreams.remove(remoteId);
      unawaited(_dashManifests.evict(remoteId));
      unawaited(_cache.evictFile(server.id, remoteId, extension: 'mp4'));
    }
    final cached = await _cache.getPath(
      server.id,
      remoteId,
      extension: _resolvedStreams[remoteId]?.ext ?? extension ?? 'flac',
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

    var isCancelled = false;
    void cancelFn() {
      isCancelled = true;
    }

    (_activeDownloads[remoteId] ??= {}).add(cancelFn);

    try {
      final request = http.Request('GET', Uri.parse(resolved.url));
      final response = await _client
          .send(request)
          .timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) {
        throw TidalException(
          'HTTP ${response.statusCode} for stream $remoteId',
        );
      }
      final total = response.contentLength;
      final builder = BytesBuilder();
      var received = 0;
      await for (final chunk in response.stream) {
        if (isCancelled) {
          throw TidalException('Playback download cancelled');
        }
        builder.add(chunk);
        received += chunk.length;
        if (onProgress != null && total != null && total > 0) {
          onProgress(received / total);
        }
      }
      if (isCancelled) {
        throw TidalException('Playback download cancelled');
      }
      return await _cache.stash(
        server.id,
        remoteId,
        builder.takeBytes(),
        extension: resolved.ext ?? extension,
      );
    } finally {
      final set = _activeDownloads[remoteId];
      if (set != null) {
        set.remove(cancelFn);
        if (set.isEmpty) {
          _activeDownloads.remove(remoteId);
        }
      }
    }
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
    // Distinct temp name on purpose: a live direct playback stream for the
    // same track writes its own `.part`; sharing that file here would truncate
    // the stream under the player's feet (audible stutter) and the two
    // downloads would race on rename/delete. `openWrite` truncates whatever
    // temp file already exists.
    final partFile = File('$targetPath.download.part');
    final sink = partFile.openWrite();

    var isCancelled = false;
    void cancelFn() {
      isCancelled = true;
    }

    (_activeDownloads[remoteId] ??= {}).add(cancelFn);

    try {
      // 1. Download initialization segment
      final initBytes = await _fetchDashBytesWithRetry(
        Uri.parse(dashInfo.initializationUrl),
        label: 'init segment',
        isCancelled: () => isCancelled,
      );
      if (isCancelled) throw TidalException('Download cancelled');
      sink.add(initBytes);

      // 2. Download media segments in a pipelined worker pool (up to 4
      // concurrent workers). Each segment is fetched with bounded retries (see
      // [_fetchDashBytesWithRetry]); only a segment that fails every attempt
      // aborts the track, so one transient CDN hiccup can't kill the download.
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
            final bytes = await _fetchDashBytesWithRetry(
              Uri.parse(myUrl),
              label: 'segment $myIndex',
              isCancelled: () => isCancelled,
            );
            if (isCancelled) return;

            completedBuffers[myIndex] = bytes;

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
      final set = _activeDownloads[remoteId];
      if (set != null) {
        set.remove(cancelFn);
        if (set.isEmpty) {
          _activeDownloads.remove(remoteId);
        }
      }
    }
  }

  /// Fetch a DASH init or media segment with bounded retries.
  ///
  /// One transient CDN hiccup (timeout, 5xx, reset) must not abort the whole
  /// track download, so each failed attempt is retried with a short backoff
  /// before the worker gives up. Individual attempts bound the response
  /// headers with [_dashSegmentHeaderTimeout] and use [_dashSegmentIdleTimeout]
  /// as a stall detector on the body: a slow-but-progressing transfer on a
  /// throttled connection keeps flowing instead of being killed by a flat
  /// total-timeout (the "download speed drops" failure mode).
  Future<List<int>> _fetchDashBytesWithRetry(
    Uri url, {
    required String label,
    required bool Function() isCancelled,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _dashSegmentAttempts; attempt++) {
      if (isCancelled()) throw TidalException('Playback download cancelled');
      try {
        return await _fetchDashBytesOnce(url, isCancelled);
      } catch (e) {
        if (isCancelled()) {
          throw TidalException('Playback download cancelled');
        }
        lastError = e;
        if (attempt >= _dashSegmentAttempts) break;
        devLog(
          '[Tidal] DASH $label attempt $attempt/$_dashSegmentAttempts failed, '
          'retrying: $e',
        );
        await Future<void>.delayed(
          _dashSegmentRetryBaseDelay * (1 << (attempt - 1)),
        );
      }
    }
    throw TidalException(
      'Failed to download DASH $label after $_dashSegmentAttempts '
      'attempts: $lastError',
    );
  }

  /// One DASH fetch attempt: headers within [_dashSegmentHeaderTimeout], body
  /// chunks may not stall for more than [_dashSegmentIdleTimeout].
  Future<List<int>> _fetchDashBytesOnce(
    Uri url,
    bool Function() isCancelled,
  ) async {
    final response = await _client
        .send(http.Request('GET', url))
        .timeout(_dashSegmentHeaderTimeout);
    if (response.statusCode != 200) {
      // Release the failed response (bounded) before surfacing the error.
      try {
        await response.stream.drain<void>().timeout(_dashSegmentIdleTimeout);
      } catch (_) {}
      throw TidalException('HTTP ${response.statusCode} for $url');
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      _dashSegmentIdleTimeout,
    )) {
      if (isCancelled()) throw TidalException('Playback download cancelled');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Resolve a directly streamable CDN url or DASH track info.
  ///
  /// Guarded by the short-TTL failure record and the timeout circuit breaker,
  /// so a silent TIDAL hang is paid for once per track (and at most three
  /// times per cooldown across tracks) instead of by every resolver pass.
  Future<TidalStreamResolution?> _resolveStreamable(
    NetworkServerEntity server,
    String trackId, {
    bool allowDolbyAtmos = false,
  }) async {
    // PlayerService resolves once for display metadata and Rust resolves
    // again to start playback. Reuse the first resolution (while the signed
    // URL is still fresh) instead of paying for a second
    // `playbackinfopostpaywall` call. This applies to both DASH and BTS.
    final cached = _reusableResolution(
      trackId,
      allowDolbyAtmos: allowDolbyAtmos,
    );
    if (cached != null) {
      // A cache hit is not evidence that TIDAL is healthy, so it clears the
      // per-track failure record but leaves the breaker untouched.
      _resolveFailures.remove(trackId);
      return cached;
    }

    // The direct `streamDescriptor` path and the `ensureLocal`/`stream`
    // fallback both land here on the same service instance; sharing the
    // failure is what prevents the second 20s hang the log showed.
    _throwIfRecentResolveFailure(trackId);
    final isProbe = _admitResolve();
    try {
      final resolved = await _resolveStreamableCascade(
        server,
        trackId,
        allowDolbyAtmos: allowDolbyAtmos,
      );
      _resolveFailures.remove(trackId);
      _onResolveSuccess();
      return resolved;
    } on _TidalHttpTimeout catch (e) {
      _onResolveTimeout(trackId, e.error);
      throw TidalUnavailableException();
    } finally {
      if (isProbe) _resolveBreakerProbeInFlight = false;
    }
  }

  /// The unguarded DOLBY_ATMOS → HI_RES_LOSSLESS → HI_RES → LOSSLESS → HIGH cascade.
  Future<TidalStreamResolution?> _resolveStreamableCascade(
    NetworkServerEntity server,
    String trackId, {
    bool allowDolbyAtmos = false,
  }) async {
    final hasAtmosHint = _hasAtmosTagByTrackId[trackId] ?? true;
    final canAttemptAtmos = allowDolbyAtmos && hasAtmosHint;

    final qualityTiers = [
      if (canAttemptAtmos) 'DOLBY_ATMOS',
      'HI_RES_LOSSLESS',
      'HI_RES',
      'LOSSLESS',
      'HIGH',
    ];
    Object? lastError;

    // Start the cascade at the catalog-known max tier when available:
    // tracks tagged non-hi-res can never satisfy the higher tiers, so
    // probing them first only burns API round-trips on every cold start.
    var tierIndex = 0;
    final hintedTier = _tierStartHintByTrackId[trackId];
    if (hintedTier != null && !canAttemptAtmos) {
      final hintedIndex = qualityTiers.indexOf(hintedTier);
      if (hintedIndex >= 0) tierIndex = hintedIndex;
    }

    for (var i = tierIndex; i < qualityTiers.length; i++) {
      final tier = qualityTiers[i];
      // Dual-Client Routing:
      // Probe Atmos and Hi-Res tiers (DOLBY_ATMOS, HI_RES_LOSSLESS, HI_RES) via hiRes client (DASH 24-bit FLAC / EAC3-JOC).
      // Probe Lossless CD tier (LOSSLESS) via lossless client (BTS unencrypted 16-bit FLAC).
      // Fallback tiers (HIGH, LOW) via lossless client.
      final profile =
          (tier == 'DOLBY_ATMOS' ||
              tier == 'HI_RES_LOSSLESS' ||
              tier == 'HI_RES')
          ? TidalClientProfile.hiRes
          : TidalClientProfile.lossless;

      try {
        final query = <String, String>{
          'playbackmode': 'STREAM',
          'assetpresentation': 'FULL',
          'audioquality': tier,
          if (canAttemptAtmos && tier == 'DOLBY_ATMOS') ...{
            'audioMode': 'DOLBY_ATMOS',
            'immersiveaudio': 'true',
          } else ...{
            'audioMode': 'STEREO',
            'immersiveaudio': 'false',
          },
        };

        final info = await _apiGet(
          server,
          '/tracks/$trackId/playbackinfopostpaywall',
          query: query,
          // Only the resolution call gets the short budget: a hung tier is
          // abandoned in 8s instead of 20s, and segment downloads keep their
          // longer timeouts.
          timeout: _streamResolveTimeout,
          profile: profile,
        );

        final mime = info['manifestMimeType'] as String?;
        final manifest = info['manifest'] as String?;
        if (manifest == null) continue;

        final rawSampleRate = (info['sampleRate'] as num?)?.toInt();
        final rawBitDepth = (info['bitDepth'] as num?)?.toInt();
        final rawQuality = (info['audioQuality'] as String?) ?? tier;
        final rawCodec = info['codec'] as String?;

        // 1. DASH manifest (Hi-Res Lossless fMP4 FLAC or Dolby Atmos EAC3-JOC)
        if (mime == 'application/dash+xml') {
          final manifestXml = utf8.decode(base64Decode(manifest));
          final dashInfo = DashManifestParser.parse(
            manifestXml,
            allowDolbyAtmos: allowDolbyAtmos,
          );
          if (dashInfo != null && dashInfo.segmentUrls.isNotEmpty) {
            final effectiveBandwidth = dashInfo.bandwidth != null
                ? (dashInfo.bandwidth! / 1000).round()
                : null;
            final explicitSampleRate = dashInfo.sampleRate ?? rawSampleRate;
            final explicitBitDepth = dashInfo.bitDepth ?? rawBitDepth;
            if (explicitSampleRate == null) {
              devLog(
                '[Tidal] DASH track $trackId omitted explicit sample rate; omitting x-flick-sample-rate header to let audio decoder probe authoritative rate',
              );
            }
            final dashCodecRaw = rawCodec ?? dashInfo.codec;
            final isAtmos =
                tier == 'DOLBY_ATMOS' ||
                dashCodecRaw?.contains('ec-3') == true ||
                dashCodecRaw?.contains('eac3') == true;
            if (isAtmos && !allowDolbyAtmos) {
              devLog(
                '[Tidal] Rejecting Atmos/EAC3 DASH stream for $trackId because allowDolbyAtmos is false',
              );
              continue;
            }
            final dashCodec = isAtmos
                ? 'eac3_joc'
                : (_normalizeCodec(dashCodecRaw, null) ?? 'flac');
            final res = TidalStreamResolution(
              url: '',
              ext: 'mp4',
              isDash: true,
              dashInfo: dashInfo,
              sampleRate: explicitSampleRate ?? (isAtmos ? 48000 : 96000),
              bitDepth:
                  explicitBitDepth ??
                  (isAtmos
                      ? 16
                      : (rawQuality == 'HI_RES_LOSSLESS' ||
                                rawQuality == 'HI_RES'
                            ? 24
                            : 16)),
              isSampleRateExplicit: explicitSampleRate != null,
              isBitDepthExplicit: explicitBitDepth != null,
              audioQuality: rawQuality,
              codec: dashCodec,
              bitrate: effectiveBandwidth,
              resolvedAt: DateTime.now(),
              tierHint: _tierStartHintByTrackId[trackId],
              profile: profile,
            );
            _resolvedStreams[trackId] = res;
            _evictOldestIfNeeded(_resolvedStreams);
            streamResolutionVersion.value++;
            return res;
          }
          continue;
        }

        // 2. BTS manifest (Direct unencrypted FLAC/AAC or EAC3-JOC)
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

          final explicitSampleRate = rawSampleRate ?? btsSampleRate;
          final explicitBitDepth = rawBitDepth ?? btsBitDepth;
          if (explicitSampleRate == null) {
            devLog(
              '[Tidal] BTS track $trackId omitted explicit sample rate; omitting x-flick-sample-rate header to let audio decoder probe authoritative rate',
            );
          }

          final btsCodecRaw =
              rawCodec ??
              (decoded['codecs'] as String?) ??
              (decoded['codec'] as String?);
          final isAtmos =
              tier == 'DOLBY_ATMOS' ||
              btsCodecRaw?.contains('ec-3') == true ||
              btsCodecRaw?.contains('eac3') == true;
          if (isAtmos && !allowDolbyAtmos) {
            devLog(
              '[Tidal] Rejecting Atmos/EAC3 BTS stream for $trackId because allowDolbyAtmos is false',
            );
            continue;
          }
          final btsCodec = isAtmos
              ? 'eac3_joc'
              : _normalizeCodec(btsCodecRaw, decoded['mimeType'] as String?);

          final res = TidalStreamResolution(
            url: urls.first as String,
            ext: isAtmos ? 'mp4' : _extFromMime(decoded['mimeType'] as String?),
            isDash: false,
            dashInfo: null,
            sampleRate: explicitSampleRate ?? (isAtmos ? 48000 : 44100),
            bitDepth: explicitBitDepth ?? 16,
            isSampleRateExplicit: explicitSampleRate != null,
            isBitDepthExplicit: explicitBitDepth != null,
            audioQuality: rawQuality,
            codec: btsCodec,
            bitrate: btsBitrate != null && btsBitrate > 10000
                ? (btsBitrate / 1000).round()
                : btsBitrate,
            resolvedAt: DateTime.now(),
            tierHint: _tierStartHintByTrackId[trackId],
            profile: profile,
          );
          _resolvedStreams[trackId] = res;
          _evictOldestIfNeeded(_resolvedStreams);
          streamResolutionVersion.value++;
          return res;
        }
      } catch (e) {
        lastError = e;
        // A silent hang is not tier evidence — TIDAL never answered, so the
        // next tier would only stack a second full timeout. Abort the cascade;
        // permanent errors (404/entitlement/429) still try the next tier.
        if (e is _TidalHttpTimeout) rethrow;
      }
    }

    if (lastError != null) {
      throw TidalException('No playable stream for $trackId: $lastError');
    }
    throw TidalException(
      'Track $trackId uses an unsupported or encrypted Tidal format (HiRes/MQA/Atmos).',
    );
  }

  /// Formats the logcat diagnostic line showing the resolved stream's
  /// track title, client profile, quality tier, dynamic codec, bit depth / sample rate,
  /// bitrate, and stream container type (DASH or BTS).
  static String formatStreamResolvedLog(
    String trackId,
    TidalClientProfile profile,
    TidalStreamResolution res,
  ) {
    final title = _trackTitleByTrackId[trackId] ?? trackId;
    final khz = (res.sampleRate / 1000).toStringAsFixed(
      res.sampleRate % 1000 == 0 ? 0 : 1,
    );
    final kbps = res.effectiveBitrate;
    final bitrateStr = kbps != null && kbps > 0 ? '${kbps}kbps' : 'VBR';
    final typeStr = res.isDash ? 'DASH' : 'BTS';
    final codecStr = res.isDolbyAtmos
        ? 'E-AC-3 JOC (Dolby Atmos)'
        : ((res.codec != null && res.codec!.isNotEmpty)
              ? res.codec!
              : (res.ext != null && res.ext != 'mp4'
                    ? res.ext!
                    : (res.isLossy ? 'aac' : 'flac')));
    return '[Tidal] Stream resolved: "$title" | profile=${profile.name} | tier=${res.audioQuality} | codec=$codecStr | ${res.bitDepth}-bit/${khz}kHz | $bitrateStr | $typeStr';
  }

  @visibleForTesting
  static String? extFromMime(String? mime) => _extFromMime(mime);

  /// The cascade start tier for a track, from the catalog `audioQuality`
  /// field AND the `mediaMetadata.tags`. Returns the HIGHEST tier either
  /// source claims, in cascade order (earlier = higher). Returns null when
  /// neither source names a tier, or for hi-res tracks (which keep the full
  /// cascade). Tags matter because they can claim LOSSLESS while the field
  /// says HIGH; using the field alone would start the cascade at HIGH and
  /// never try LOSSLESS, hiding a CD stream the track may serve.
  @visibleForTesting
  static String? tierStartHintFor(String? quality, List<String> tags) {
    const order = ['HI_RES_LOSSLESS', 'HI_RES', 'LOSSLESS', 'HIGH'];
    String? best;
    void consider(String? tier) {
      if (tier == null) return;
      final index = order.indexOf(tier);
      if (index < 0) return;
      if (best == null || index < order.indexOf(best!)) best = tier;
    }

    if (tags.contains('HIRES_LOSSLESS') ||
        tags.contains('HIRES_LOSSLESS_MQA') ||
        quality == 'HI_RES_LOSSLESS') {
      return null;
    }
    consider(switch (quality) {
      'HI_RES' => 'HI_RES',
      'LOSSLESS' => 'LOSSLESS',
      'HIGH' => 'HIGH',
      _ => null,
    });
    if (tags.contains('LOSSLESS')) consider('LOSSLESS');
    return best;
  }

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

  @visibleForTesting
  static String? normalizeCodec(String? codec, String? mime) =>
      _normalizeCodec(codec, mime);
  static String? _normalizeCodec(String? codec, String? mime) {
    final c = codec?.trim().toLowerCase();
    if (c != null && c.isNotEmpty) {
      if (c == 'eac3' ||
          c == 'eac3_joc' ||
          c == 'ec-3' ||
          c.contains('eac3') ||
          c.contains('ec-3')) {
        return 'eac3_joc';
      }
      if (c.startsWith('mp4a')) return 'aac';
      if (c.contains('flac')) return 'flac';
      if (c.contains('alac')) return 'alac';
      if (c.contains('mp3') || c == 'mpeg') return 'mp3';
      return c;
    }
    final m = mime?.trim().toLowerCase();
    if (m != null) {
      if (m == 'audio/eac3-joc' || m == 'audio/eac3' || m == 'audio/ec-3') {
        return 'eac3_joc';
      }
      if (m == 'audio/mp4' || m == 'audio/m4a' || m == 'audio/x-m4a') {
        return 'aac';
      }
      if (m == 'audio/flac' || m == 'audio/x-flac') return 'flac';
      if (m == 'audio/mpeg') return 'mp3';
    }
    return null;
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
    Map<String, dynamic> rawTrackJson,
  ) {
    final t =
        rawTrackJson.containsKey('item') &&
            rawTrackJson['item'] is Map<String, dynamic>
        ? rawTrackJson['item'] as Map<String, dynamic>
        : rawTrackJson;
    final remoteId = t['id']?.toString();
    if (remoteId == null) return null;
    final title = t['title'] as String?;
    if (title != null && title.isNotEmpty) {
      recordTrackTitle(remoteId, title);
    }
    final artists = (t['artists'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>?>();
    final album = t['album'] as Map<String, dynamic>?;
    final durationSec = (t['duration'] as num?)?.toInt();
    final cover = (album?['cover'] as String?) ?? (t['cover'] as String?);
    return SongEntity()
      ..filePath = '${NetworkProtocol.tidal}://${server.id}/$remoteId'
      ..title = (t['title'] as String?) ?? 'Unknown'
      ..artist =
          joinArtistNames(artists) ??
          ((album?['artist'] as Map<String, dynamic>?)?['name'] as String?) ??
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
      ..isExplicit = t['explicit'] == true
      ..isAtmos =
          (rawTrackJson['audioModes'] as List?)?.contains('DOLBY_ATMOS') ==
              true ||
          (t['audioModes'] as List?)?.contains('DOLBY_ATMOS') == true ||
          ((t['mediaMetadata'] as Map<String, dynamic>?)?['tags'] as List?)
                  ?.contains('DOLBY_ATMOS') ==
              true
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
        'countryCode': _countryCode(server.token),
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
  /// Paginates through all pages so long albums / DJ mixes aren't silently
  /// truncated at the API's default page size.
  Future<List<Map<String, dynamic>>> getAlbumTracks(
    NetworkServerEntity server,
    String albumId,
  ) async {
    const pageSize = 100;
    final allItems = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final res = await _apiGet(
        server,
        '/albums/$albumId/tracks',
        query: {'limit': '$pageSize', 'offset': '$offset'},
      );
      final items = (res['items'] as List<dynamic>?) ?? [];
      if (items.isEmpty) break;
      allItems.addAll(items.cast<Map<String, dynamic>>());
      if (items.length < pageSize) break;
      offset += pageSize;
    }
    return allItems;
  }

  /// Get metadata for a specific playlist by its [playlistId].
  Future<Map<String, dynamic>> getPlaylist(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    return _apiGet(server, '/playlists/$playlistId');
  }

  /// Get track items for a specific playlist by its [playlistId].
  /// Paginates through all pages so long playlists aren't silently truncated
  /// at the first page. The [limit]/[offset] params control page size and
  /// start position.
  Future<List<Map<String, dynamic>>> getPlaylistTracks(
    NetworkServerEntity server,
    String playlistId, {
    int limit = 100,
    int offset = 0,
  }) async {
    final allItems = <Map<String, dynamic>>[];
    var pageOffset = offset;
    while (true) {
      final page = await _getPlaylistTracksPage(
        server,
        playlistId,
        limit: limit,
        offset: pageOffset,
      );
      if (page.isEmpty) break;
      allItems.addAll(page);
      if (page.length < limit) break;
      pageOffset += limit;
    }
    return allItems;
  }

  /// Fetches a single page of playlist tracks, trying /items then /tracks.
  Future<List<Map<String, dynamic>>> _getPlaylistTracksPage(
    NetworkServerEntity server,
    String playlistId, {
    required int limit,
    required int offset,
  }) async {
    // Official TIDAL API uses /playlists/{id}/items (wrapping each entry in {"item": ..., "type": "track"}),
    // NOT /playlists/{id}/tracks.
    try {
      final res = await _apiGet(
        server,
        '/playlists/$playlistId/items',
        query: {'limit': '$limit', 'offset': '$offset'},
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
          query: {'limit': '$limit', 'offset': '$offset'},
        );
        final rawList = (res['items'] ?? res['data']) as List<dynamic>? ?? [];
        return rawList.whereType<Map<String, dynamic>>().toList();
      } catch (e2) {
        devLog('[Tidal] /playlists/$playlistId/tracks failed ($e2)');
        // Don't swallow: let the provider surface an honest error state
        // instead of showing a misleading "0 tracks".
        throw StateError('Failed to load playlist tracks: $e2');
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

  /// Fetch an artist's biography text, or null when the artist has none.
  ///
  /// The v1 artist object carries no bio; the v2 API exposes it through the
  /// `biography` relationship. `include=biography` expands it into the
  /// `included` array (resource type `artistBiographies`) so a single request
  /// is enough. Biography text is decorative — every failure mode (missing
  /// relationship, HTTP error, malformed payload) resolves to null instead of
  /// throwing, and the caller simply skips the section.
  Future<String?> getArtistBio(
    NetworkServerEntity server,
    String artistId,
  ) async {
    try {
      final raw = await _apiV2GetRaw(
        server,
        '/artists/$artistId',
        query: {'include': 'biography'},
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final data = decoded['data'];
      final relationships = data is Map ? data['relationships'] : null;
      final biography = relationships is Map
          ? relationships['biography']
          : null;
      final referenceRaw = biography is Map ? biography['data'] : null;
      final reference = referenceRaw is List
          ? (referenceRaw.isEmpty ? null : referenceRaw.first)
          : referenceRaw;
      final bioId = reference is Map ? reference['id']?.toString() : null;

      final included = decoded['included'];
      if (bioId == null || included is! List) return null;
      for (final resource in included) {
        if (resource is! Map || resource['id']?.toString() != bioId) continue;
        final attributes = resource['attributes'];
        final text = attributes is Map
            ? attributes['text']?.toString().trim()
            : null;
        if (text != null && text.isNotEmpty) return text;
      }
      return null;
    } catch (e) {
      devLog('[Tidal] getArtistBio($artistId) failed: $e');
      return null;
    }
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

    String? rawBody;
    try {
      rawBody = await _apiV2GetRaw(
        server,
        '/home/feed/$feedSlug',
        query: query,
      );
    } catch (e) {
      // A 429 is not "V2 unavailable": TIDAL is explicitly asking us to stop.
      // Falling back would fire three more V1 requests (each with its own
      // 429 retry chain) precisely when the server is rate-limiting, and the
      // resulting empty feed would hide the 429 from TidalErrorWidget. Let
      // the exception reach the UI so it can show the rate-limit state and
      // a retry button.
      if (_isTidalRateLimitFailure(e)) rethrow;
      devLog(
        '[Tidal] v2 home feed failed ($e), falling back to v1 multi-endpoints...',
      );
    }

    if (rawBody != null) {
      // Parse off the UI thread: home-feed payloads are large and both
      // jsonDecode and model construction would otherwise drop frames.
      final feed = await compute(parseTidalHomeFeedBody, rawBody);
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

    // Fetch the three pages in parallel — they're independent. A null entry
    // means that endpoint failed; one bad endpoint doesn't kill the others.
    Future<String?> fetchPage(String path) async {
      try {
        return await _apiGetRaw(
          server,
          path,
          query: {'deviceType': 'BROWSER', 'locale': 'en_US'},
        );
      } catch (e) {
        // Same rule as the V2 path: never hide a rate-limit behind a partial
        // or empty feed. Surface it so the UI can back off and offer retry.
        if (_isTidalRateLimitFailure(e)) rethrow;
        devLog('[Tidal] v1 $path failed: $e');
        return null;
      }
    }

    final bodies = await Future.wait([
      fetchPage('/pages/my_collection_my_mixes'),
      fetchPage('/pages/for_you'),
      fetchPage('/pages/home'),
    ]);

    // Parse all payloads off the UI thread in a single isolate call.
    // Index 0 = mixes, 1 = for-you, 2 = home (home also provides tabs/cursor).
    final validIndices = <int>[];
    final validBodies = <String>[];
    for (var i = 0; i < bodies.length; i++) {
      final body = bodies[i];
      if (body != null) {
        validIndices.add(i);
        validBodies.add(body);
      }
    }
    final feedsByPage = <int, TidalHomeFeed>{};
    if (validBodies.isNotEmpty) {
      final parsed = await compute(parseTidalHomeFeedBodies, validBodies);
      for (var j = 0; j < parsed.length; j++) {
        feedsByPage[validIndices[j]] = parsed[j];
      }
    }

    final mixesFeed = feedsByPage[0];
    if (mixesFeed != null) addUniqueSections(mixesFeed.sections);

    final forYouFeed = feedsByPage[1];
    if (forYouFeed != null) addUniqueSections(forYouFeed.sections);

    final homeFeed = feedsByPage[2];
    if (homeFeed != null) {
      addUniqueSections(homeFeed.sections);
      return TidalHomeFeed(
        tabs: homeFeed.tabs,
        sections: allSections,
        cursor: homeFeed.cursor,
      );
    }
    return TidalHomeFeed(
      tabs: const [
        TidalHomeTab(name: 'Suggested', type: 'STATIC', slug: 'static'),
      ],
      sections: allSections,
    );
  }

  /// Parses a home feed response, handling V2 and V1 module structures.
  /// Pure: only builds model objects from [json], no instance state, so it can
  /// also run on a background isolate via [parseTidalHomeFeedBody].
  static TidalHomeFeed _parseHomeFeed(Map<String, dynamic> json) {
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
        String? description;
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
                // Editorial description — not present in today's mix
                // payloads, so the About section stays hidden until it is.
                final descriptionRaw = (mixObj['description'] as String?)
                    ?.trim();
                if (descriptionRaw != null && descriptionRaw.isNotEmpty) {
                  description = descriptionRaw;
                }
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
            description: description,
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

  /// Fetches track metadata by id (returns full JSON including `mixes` dictionary).
  Future<Map<String, dynamic>> getTrackDetail(
    NetworkServerEntity server,
    String trackId,
  ) async {
    final detail = await _apiGet(server, '/tracks/$trackId');
    final title = detail['title'] as String?;
    if (title != null && title.isNotEmpty) {
      recordTrackTitle(trackId, title);
    }
    return detail;
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

  /// Fetches TIDAL Radio tracks for a given TIDAL track ID.
  /// Uses TIDAL's own TRACK_MIX algorithm (same as "Start Radio").
  /// Returns empty list if unavailable. Tracks are ephemeral Songs ready to play.
  Future<List<Song>> getRadioTracks(String trackId) async {
    try {
      final servers = await Database.networkServers.where().findAll();
      NetworkServerEntity? server;
      for (final s in servers) {
        if (s.protocol == NetworkProtocol.tidal) {
          server = s;
          break;
        }
      }
      if (server == null) {
        devLog('[Tidal] getRadioTracks: no TIDAL server found');
        return [];
      }
      final mixId = await getTrackRadioMixId(server, trackId);
      if (mixId == null || mixId.isEmpty) {
        devLog('[Tidal] getRadioTracks: no TRACK_MIX for $trackId');
        return [];
      }
      final mix = await getMix(server, mixId);
      return mix.tracks;
    } catch (e) {
      devLog('[Tidal] getRadioTracks failed for $trackId: $e');
      return [];
    }
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

      // Telemetry shares TIDAL's client_id rate-limit budget with the main
      // API. Send it through the same gate and retry policy as every other
      // call; otherwise each played song fires an unthrottled POST that can
      // push the next catalog request into a 429. Failures stay non-fatal:
      // this catch only logs, so playback never depends on telemetry.
      await _throttle();
      final res = await _with429Retry(
        'POST playback session',
        () => _client
            .post(
              Uri.parse(_eventCollectorUrl),
              headers: {
                'Authorization': 'Bearer ${creds.accessToken}',
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: formFields,
            )
            .timeout(const Duration(seconds: 10)),
      );

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
    const pageSize = 100;
    const maxTracks = 5000;
    final ids = <String>{};
    var offset = 0;
    try {
      while (offset < maxTracks) {
        final res = await _apiGet(
          server,
          '/users/$userId/favorites/tracks',
          query: {'limit': '$pageSize', 'offset': '$offset'},
        );
        final items = res['items'] as List<dynamic>?;
        if (items == null || items.isEmpty) break;
        for (final it in items) {
          if (it is Map<String, dynamic>) {
            final item = it['item'] as Map<String, dynamic>?;
            final id = item?['id']?.toString() ?? it['id']?.toString();
            if (id != null && id.isNotEmpty) {
              ids.add(id);
            }
          }
        }
        if (items.length < pageSize) break;
        offset += pageSize;
      }
      return ids;
    } catch (e) {
      devLog('[Tidal] getFavoriteTrackIds error: $e');
      return ids;
    }
  }

  /// Get the user's TIDAL favorite tracks with full metadata as [Song]s.
  /// Used for the "Liked Songs" collection view.
  Future<List<Song>> getFavoriteTracks(NetworkServerEntity server) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return [];
    // Paginate: the API returns oldest-first, so a single page would miss
    // recently liked tracks.
    const pageSize = 100;
    const maxTracks = 5000;
    final songs = <Song>[];
    var offset = 0;
    try {
      while (offset < maxTracks) {
        final res = await _apiGet(
          server,
          '/users/$userId/favorites/tracks',
          query: {'limit': '$pageSize', 'offset': '$offset'},
        );
        final items = res['items'] as List<dynamic>?;
        if (items == null || items.isEmpty) break;
        for (final it in items) {
          if (it is Map<String, dynamic>) {
            final trackJson = it['item'] as Map<String, dynamic>?;
            if (trackJson != null) {
              DateTime? dateAdded;
              final createdStr = it['created'] as String?;
              if (createdStr != null) {
                dateAdded = DateTime.tryParse(createdStr);
              }
              final song = makeEphemeralSong(
                server,
                trackJson,
              ).copyWith(dateAdded: dateAdded);
              songs.add(song);
            }
          }
        }
        if (items.length < pageSize) break;
        offset += pageSize;
      }
      if (songs.any((s) => s.dateAdded != null)) {
        songs.sort((a, b) {
          final bDate = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final aDate = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bDate.compareTo(aDate);
        });
      } else {
        return songs.reversed.toList();
      }
      return songs;
    } catch (e) {
      devLog('[Tidal] getFavoriteTracks error: $e');
      return songs;
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

  /// Get the set of favorite artist IDs in the user's TIDAL account.
  ///
  /// Mirrors [getFavoriteTrackIds]: paginated, capped, and returning the IDs
  /// collected so far on error so the UI can fall back to "not followed"
  /// instead of breaking.
  Future<Set<String>> getFavoriteArtistIds(NetworkServerEntity server) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return {};
    const pageSize = 100;
    const maxArtists = 5000;
    final ids = <String>{};
    var offset = 0;
    try {
      while (offset < maxArtists) {
        final res = await _apiGet(
          server,
          '/users/$userId/favorites/artists',
          query: {'limit': '$pageSize', 'offset': '$offset'},
        );
        final items = res['items'] as List<dynamic>?;
        if (items == null || items.isEmpty) break;
        for (final it in items) {
          if (it is Map<String, dynamic>) {
            final item = it['item'] as Map<String, dynamic>?;
            final id = item?['id']?.toString() ?? it['id']?.toString();
            if (id != null && id.isNotEmpty) {
              ids.add(id);
            }
          }
        }
        if (items.length < pageSize) break;
        offset += pageSize;
      }
      return ids;
    } catch (e) {
      devLog('[Tidal] getFavoriteArtistIds error: $e');
      return ids;
    }
  }

  /// Follow an artist (add to the account's TIDAL favorites).
  Future<void> addFavoriteArtist(
    NetworkServerEntity server,
    String artistId,
  ) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return;
    final url = '$_apiBase/users/$userId/favorites/artists';
    final res = await _apiAuthPostForm(server, url, {'artistId': artistId});
    if (res.statusCode >= 400) {
      devLog(
        '[Tidal] addFavoriteArtist failed: HTTP ${res.statusCode} ${res.body}',
      );
      throw TidalException('Failed to follow artist: HTTP ${res.statusCode}');
    }
  }

  /// Unfollow an artist (remove from the account's TIDAL favorites).
  Future<void> removeFavoriteArtist(
    NetworkServerEntity server,
    String artistId,
  ) async {
    final creds = _creds(server.token);
    final userId = creds?.userId;
    if (userId == null || userId.isEmpty) return;
    final url = '$_apiBase/users/$userId/favorites/artists/$artistId';
    final res = await _apiAuthDelete(server, url);
    if (res.statusCode >= 400) {
      devLog(
        '[Tidal] removeFavoriteArtist failed: HTTP ${res.statusCode} ${res.body}',
      );
      throw TidalException('Failed to unfollow artist: HTTP ${res.statusCode}');
    }
  }

  /// Get track credits (writers, composers, producers, etc.) from TIDAL.
  /// Returns a list of {type, name} maps, one per contributor.
  ///
  /// Verified against the live API (2026-10): `GET /tracks/{id}/credits`
  /// returns a **top-level JSON array** of role groups — not an `{items: …}`
  /// envelope — and the role key is `type`, not `creditType`:
  ///
  ///   [{"type": "Composer",
  ///     "contributors": [{"name": "Pharrell Williams", "id": 4900204}, …]}, …]
  ///
  /// A track with no credits returns HTTP 200 with an empty array. API,
  /// network and parse failures throw instead of silently returning `[]`, so
  /// the UI can tell "failed to load" apart from "no credits"; every failure
  /// is also recorded in the in-app log (visible in release builds).
  Future<List<Map<String, String>>> getTrackCredits(
    NetworkServerEntity server,
    String trackId,
  ) async {
    final String raw;
    try {
      raw = await _apiGetRaw(server, '/tracks/$trackId/credits');
    } catch (e) {
      // TidalException carries the HTTP status + path (401/404/429/…);
      // transport failures carry their own message.
      AppLog.instance.add('[Tidal] getTrackCredits($trackId) failed: $e');
      rethrow;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw FormatException(
          'expected a JSON array of credit groups, got ${decoded.runtimeType}',
        );
      }
      final credits = <Map<String, String>>[];
      for (final group in decoded) {
        if (group is! Map<String, dynamic>) continue;
        final type = group['type'] as String? ?? 'Contributor';
        final contributors = group['contributors'] as List<dynamic>?;
        if (contributors == null) continue;
        for (final c in contributors) {
          if (c is Map<String, dynamic>) {
            final name = c['name'] as String? ?? '';
            if (name.isNotEmpty) {
              credits.add({'type': type, 'name': name});
            }
          }
        }
      }
      return credits;
    } catch (e) {
      final excerpt = raw.length > 500 ? '${raw.substring(0, 500)}…' : raw;
      AppLog.instance.add(
        '[Tidal] getTrackCredits($trackId) parse error: $e | body: $excerpt',
      );
      rethrow;
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

  /// Delete a TIDAL playlist by its ID. Best-effort: returns true on success.
  Future<bool> deletePlaylist(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    try {
      final cc = _countryCode(server.token);
      final url = cc.isNotEmpty
          ? '$_openapiBase/playlists/$playlistId?countryCode=$cc'
          : '$_openapiBase/playlists/$playlistId';
      final res = await _apiAuthDelete(server, url);
      return res.statusCode < 300;
    } catch (e) {
      devLog('[Tidal] deletePlaylist failed for $playlistId ($e)');
      return false;
    }
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
    final title = trackJson['title'] as String?;
    if (remoteId.isNotEmpty && title != null && title.isNotEmpty) {
      recordTrackTitle(remoteId, title);
    }
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
    final hasAtmos =
        tags.contains('DOLBY_ATMOS') ||
        (rawTrackJson['audioModes'] as List?)?.contains('DOLBY_ATMOS') ==
            true ||
        (trackJson['audioModes'] as List?)?.contains('DOLBY_ATMOS') == true;
    if (remoteId.isNotEmpty) {
      _hasAtmosTagByTrackId[remoteId] = hasAtmos;
      _evictOldestIfNeeded(_hasAtmosTagByTrackId);
    }
    // Remember the catalog-known max tier so the stream-resolution cascade
    // can skip higher tiers this track can never satisfy. Hi-res tracks
    // keep the full cascade (subscription/region may still downgrade them);
    // unknown quality keeps it too as the safe fallback.
    // The hint is the HIGHEST tier claimed by EITHER catalog source: the
    // `audioQuality` field and the `mediaMetadata.tags`. The two can
    // disagree (tags say LOSSLESS while the field says HIGH); trusting the
    // field alone would start the cascade at HIGH and never even try
    // LOSSLESS, hiding a CD stream the track may actually serve.
    if (remoteId.isNotEmpty && !isHiRes) {
      final startTier = tierStartHintFor(quality, tags);
      if (startTier != null) {
        _tierStartHintByTrackId[remoteId] = startTier;
        _evictOldestIfNeeded(_tierStartHintByTrackId);
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

    final createdStr =
        (rawTrackJson['created'] as String?) ??
        (trackJson['created'] as String?);
    final dateAdded = createdStr != null ? DateTime.tryParse(createdStr) : null;
    final explicit = trackJson['explicit'] == true;

    return Song(
      id: 'tidal_${server.id}_$remoteId',
      title: (trackJson['title'] as String?) ?? 'Unknown Track',
      artist:
          joinArtistNames(artists) ??
          ((album?['artist'] as Map<String, dynamic>?)?['name'] as String?) ??
          'Unknown Artist',
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
      dateAdded: dateAdded,
      isExplicit: explicit,
      isAtmos: hasAtmos,
    );
  }
}

/// Tidal client profile used for dual-client routing.
enum TidalClientProfile {
  /// Hi-Res profile (Android Automotive HiRes / fX2JxdmntZWK0ixT).
  ///
  /// Delivers 24-bit DASH FLAC streams for tracks with Hi-Res Master available.
  hiRes,

  /// Lossless CD profile (Android Automotive_new2 / 4N3n6Q1x95LL5K7p).
  ///
  /// Delivers true unencrypted 16-bit / 44.1 kHz BTS FLAC streams for standard
  /// CD-quality catalog tracks without server-side downgrade to AAC.
  lossless,
}

typedef _TidalCreds = TidalCreds;

class TidalCreds {
  const TidalCreds({
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

  bool get isNearExpiry {
    if (expiresAtMs == null) return true;
    return DateTime.now().millisecondsSinceEpoch > expiresAtMs! - 60000;
  }

  TidalCreds copyWith({
    String? accessToken,
    String? refreshToken,
    String? userId,
    String? countryCode,
    int? expiresAtMs,
  }) => TidalCreds(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    userId: userId ?? this.userId,
    countryCode: countryCode ?? this.countryCode,
    expiresAtMs: expiresAtMs ?? this.expiresAtMs,
  );
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

/// A TIDAL request that reached the server and came back non-200.
///
/// Keeps [statusCode] so callers can distinguish "this track has no lyrics"
/// (404) from a transport or entitlement failure without matching on the
/// message text. Still a [TidalException], so every existing catch site keeps
/// working unchanged.
class TidalHttpException extends TidalException {
  final int statusCode;

  TidalHttpException(this.statusCode, String path)
    : super('HTTP $statusCode for $path');
}

/// Thrown when TIDAL rate-limits us (HTTP 429) and all retries are exhausted.
/// Callers should surface [message] directly — it already tells the user to
/// wait a moment instead of looking like a connection failure.
class TidalRateLimitedException extends TidalException {
  TidalRateLimitedException([int? retryAfterSeconds])
    : super(
        retryAfterSeconds != null && retryAfterSeconds > 0
            ? 'Too many TIDAL requests. Try again in ~$retryAfterSeconds seconds.'
            : 'Too many TIDAL requests. Wait a moment and try again.',
      );
}

/// Thrown when TIDAL is not answering at all (silent hang or open breaker).
///
/// Callers should surface [message] directly: the resolve was abandoned
/// quickly on purpose instead of leaving the UI loading for 40 seconds.
class TidalUnavailableException extends TidalException {
  TidalUnavailableException([Duration? retryAfter])
    : super(
        retryAfter != null && retryAfter > Duration.zero
            ? 'TIDAL is not responding — try again in ~${retryAfter.inSeconds}s.'
            : 'TIDAL is not responding — try again in a moment.',
      );
}

/// The HTTP attempt for a stream-resolution call itself timed out: TIDAL
/// accepted the connection and never answered.
///
/// Distinguished from other [TimeoutException]s (keystore reads, token
/// refresh) so those are not misdiagnosed as a dead TIDAL endpoint.
class _TidalHttpTimeout implements Exception {
  const _TidalHttpTimeout(this.error);
  final TimeoutException error;
}

/// One negative-cache entry: the typed error to replay and when it happened.
class _ResolveFailure {
  const _ResolveFailure(this.error, this.at);
  final TidalUnavailableException error;
  final DateTime at;
}

/// Whether [error] is, or wraps, a TIDAL rate-limit failure.
///
/// The raw-body helpers throw [TidalRateLimitedException] directly. Higher
/// layers may wrap it in a generic exception, so also recognize the canonical
/// message rather than silently treating it as a transport failure.
bool _isTidalRateLimitFailure(Object error) {
  if (error is TidalRateLimitedException) return true;
  final message = error is TidalException ? error.message : error.toString();
  return message.contains('Too many TIDAL requests');
}

/// Bitstream family implied by a manifest codec string.
enum _StreamCodecFamily { lossless, lossy, unknown }

/// Resolved stream metadata and endpoint details for a TIDAL track.
class TidalStreamResolution {
  final String url;
  final String? ext;
  final bool isDash;
  final DashTrackInfo? dashInfo;
  final int sampleRate;
  final int bitDepth;
  final bool isSampleRateExplicit;
  final bool isBitDepthExplicit;
  final String audioQuality;
  final String? codec;

  final int? bitrate;

  /// When this resolution was fetched. Used to expire signed CDN URLs.
  final DateTime? resolvedAt;

  /// Catalog quality hint in effect when this resolution was fetched.
  /// A change invalidates the cached resolution because it changes which
  /// tier the quality cascade started from.
  final String? tierHint;

  /// The client profile used to resolve this stream.
  final TidalClientProfile? profile;

  /// Whether this stream is encoded in Dolby Atmos (E-AC-3 JOC).
  bool get isDolbyAtmos =>
      codec == 'eac3_joc' || codec == 'ec-3' || audioQuality == 'DOLBY_ATMOS';

  /// Bitstream family implied by [codec].
  ///
  /// The container is deliberately absent: an MP4/M4A container carries ALAC,
  /// FLAC and AAC alike, so it says nothing about the payload.
  _StreamCodecFamily get _codecFamily {
    final c = codec?.trim().toLowerCase();
    if (c == null || c.isEmpty) return _StreamCodecFamily.unknown;
    // TidalService._normalizeCodec already collapses `mp4a.*` to `aac` and
    // matches flac/alac substrings, but a directly constructed resolution may
    // still carry a raw codec string, so classify defensively.
    if (c.contains('flac') || c.contains('alac')) {
      return _StreamCodecFamily.lossless;
    }
    if (c == 'wav' || c == 'pcm' || c == 'lpcm' || c == 'aiff' || c == 'dsd') {
      return _StreamCodecFamily.lossless;
    }
    if (c.startsWith('mp4a') ||
        c.contains('aac') ||
        c.contains('mp3') ||
        c == 'mpeg' ||
        c.contains('opus') ||
        c.contains('vorbis')) {
      return _StreamCodecFamily.lossy;
    }
    return _StreamCodecFamily.unknown;
  }

  /// Whether the resolved stream is lossy, decided by evidence strength:
  ///
  /// 1. Codec from the manifest (ground truth): flac/alac/wav are lossless,
  ///    aac/mp3/opus/vorbis are lossy.
  /// 2. Catalog tier (`HIGH`/`LOW`) only when the codec is unknown.
  /// 3. Container extension as a last resort — `mp3` only. `m4a`/`mp4` must
  ///    never imply lossy: ALAC is always MP4-packaged and FLAC-in-MP4 is
  ///    valid, so the extension would veto a lossless codec.
  bool get isLossy {
    switch (_codecFamily) {
      case _StreamCodecFamily.lossless:
        return false;
      case _StreamCodecFamily.lossy:
        return true;
      case _StreamCodecFamily.unknown:
        break;
    }
    if (audioQuality == 'HIGH' || audioQuality == 'LOW') return true;
    return ext == 'mp3';
  }

  int? get effectiveBitrate {
    if (bitrate != null && bitrate! > 0) return bitrate;
    if (dashInfo?.bandwidth != null) {
      return (dashInfo!.bandwidth! / 1000).round();
    }

    // Same precedence as [isLossy]: codec evidence must not borrow another
    // codec's nominal rate. A downgraded AAC stream reporting a lossless
    // tier would otherwise claim FLAC's 1411 kbps.
    switch (_codecFamily) {
      case _StreamCodecFamily.lossy:
        return audioQuality == 'LOW' ? 96 : 320;
      case _StreamCodecFamily.lossless:
        if (audioQuality == 'LOSSLESS' &&
            sampleRate == 44100 &&
            bitDepth <= 16) {
          return 1411;
        }
        return null;
      case _StreamCodecFamily.unknown:
        break;
    }

    if (audioQuality == 'HIGH') return 320;
    if (audioQuality == 'LOW') return 96;
    if (!isLossy &&
        audioQuality == 'LOSSLESS' &&
        sampleRate == 44100 &&
        bitDepth <= 16) {
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
    this.isSampleRateExplicit = true,
    this.isBitDepthExplicit = true,
    required this.audioQuality,
    this.codec,
    this.bitrate,
    this.resolvedAt,
    this.tierHint,
    this.profile,
  });

  String get resolutionString {
    if (isDolbyAtmos) {
      final kbps = effectiveBitrate;
      final bitrateStr = (kbps != null && kbps > 0) ? ' / ${kbps}kbps' : '';
      return 'Dolby Atmos · 48kHz$bitrateStr';
    }
    final kbps = effectiveBitrate;
    if (isLossy) {
      if (kbps != null && kbps > 0) {
        return '${kbps}kbps';
      }
      return 'Lossy';
    }

    final parts = <String>[];
    parts.add('$bitDepth-bit');
    final khz = sampleRate / 1000;
    final khzStr = sampleRate % 1000 == 0
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    parts.add('${khzStr}kHz');
    if (kbps != null && kbps > 0) {
      parts.add('${kbps}kbps');
    }
    return parts.join(' / ');
  }
}
