/// Lyrics for a TIDAL track, as served by `GET /v1/tracks/{id}/lyrics`.
///
/// This endpoint is community-documented (independent TIDAL clients and
/// proxies), not part of TIDAL's published API reference, so every field is
/// optional: `subtitles` may be absent on tracks that only carry plain
/// `lyrics`, and vice versa. Nothing here is synthesized when the payload
/// omits it.
///
/// `subtitles` is line-level LRC (`[mm:ss.cc] text`), not enhanced/word-level
/// LRC; `isRightToLeft` marks scripts (Arabic, Hebrew, …) that must render
/// right-to-left.
class TidalLyrics {
  /// The TIDAL track id this lyrics payload belongs to.
  final String trackId;

  /// Lyrics provider name (`MUSIXMATCH`, `LYRICFIND`, …), when reported.
  final String? lyricsProvider;

  /// Provider-side common track id, when reported.
  final String? providerCommontrackId;

  /// Provider-side lyrics id, when reported.
  final String? providerLyricsId;

  /// Whether the lyrics must be laid out right-to-left.
  final bool isRightToLeft;

  /// Plain-text lyrics, without timestamps.
  final String? lyrics;

  /// Line-level LRC, with `[mm:ss.cc]` timestamps.
  final String? subtitles;

  const TidalLyrics({
    required this.trackId,
    this.lyricsProvider,
    this.providerCommontrackId,
    this.providerLyricsId,
    this.isRightToLeft = false,
    this.lyrics,
    this.subtitles,
  });

  /// Parse a lyrics payload for [requestedTrackId].
  ///
  /// TIDAL returns the fields at the top level; some TIDAL-proxy projects wrap
  /// them in a `lyrics` object. Both shapes are accepted so a change in the
  /// endpoint's envelope cannot silently blank the feature out.
  factory TidalLyrics.fromJson(
    String requestedTrackId,
    Map<String, dynamic> json,
  ) {
    final nested = json['lyrics'];
    final payload = nested is Map<String, dynamic> ? nested : json;

    final rawTrackId = payload['trackId'];
    final payloadTrackId = rawTrackId?.toString().trim();

    return TidalLyrics(
      trackId: (payloadTrackId == null || payloadTrackId.isEmpty)
          ? requestedTrackId
          : payloadTrackId,
      lyricsProvider: _stringOrNull(payload['lyricsProvider']),
      providerCommontrackId: _stringOrNull(payload['providerCommontrackId']),
      providerLyricsId: _stringOrNull(payload['providerLyricsId']),
      isRightToLeft: payload['isRightToLeft'] == true,
      lyrics: _textOrNull(payload['lyrics']),
      subtitles: _textOrNull(payload['subtitles']),
    );
  }

  bool get hasSubtitles => subtitles != null;

  bool get hasPlainLyrics => lyrics != null;

  /// True when the payload carries nothing renderable, i.e. the caller must
  /// fall through to the next lyrics source.
  bool get isEmpty => !hasSubtitles && !hasPlainLyrics;

  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Keeps the original string (line breaks matter for LRC) but treats a
  /// whitespace-only value as absent.
  static String? _textOrNull(Object? value) {
    if (value is! String) return null;
    return value.trim().isEmpty ? null : value;
  }
}
