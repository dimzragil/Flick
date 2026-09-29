import 'package:xml/xml.dart';

/// Information parsed from a DASH MPD manifest for playback.
class DashTrackInfo {
  final String? codec;
  final int? sampleRate;
  final int? bitDepth;
  final String initializationUrl;
  final List<String> segmentUrls;
  final String mimeType;
  final int? bandwidth;
  final double? durationSeconds;

  const DashTrackInfo({
    this.codec,
    this.sampleRate,
    this.bitDepth,
    required this.initializationUrl,
    required this.segmentUrls,
    this.mimeType = 'audio/mp4',
    this.bandwidth,
    this.durationSeconds,
  });
}

/// Lightweight parser for MPEG-DASH (MPD) manifests used by Tidal for Hi-Res audio.
class DashManifestParser {
  DashManifestParser._();

  /// Parse raw MPD XML string into a playable [DashTrackInfo].
  /// Returns null if the XML is malformed or lacks required audio elements.
  static DashTrackInfo? parse(String xmlContent) {
    try {
      final doc = XmlDocument.parse(xmlContent);
      final mpd = doc.getElement('MPD');
      if (mpd == null) return null;

      final baseUrl = _findBaseUrl(doc);

      // Find audio AdaptationSets
      final adaptationSets = doc.findAllElements('AdaptationSet');
      XmlElement? audioAdaptation;
      for (final set in adaptationSets) {
        final mime = set.getAttribute('mimeType');
        final contentType = set.getAttribute('contentType');
        if (mime?.startsWith('audio') == true || contentType == 'audio') {
          audioAdaptation = set;
          break;
        }
      }
      audioAdaptation ??= adaptationSets.firstOrNull;
      if (audioAdaptation == null) return null;

      // Find Representations
      final representations = audioAdaptation.findAllElements('Representation').toList();
      if (representations.isEmpty) return null;

      // Sort representations to pick highest quality (audioSamplingRate, then bandwidth)
      representations.sort((a, b) {
        final rateA = int.tryParse(a.getAttribute('audioSamplingRate') ?? '') ?? 0;
        final rateB = int.tryParse(b.getAttribute('audioSamplingRate') ?? '') ?? 0;
        if (rateA != rateB) return rateB.compareTo(rateA);
        final bwA = int.tryParse(a.getAttribute('bandwidth') ?? '') ?? 0;
        final bwB = int.tryParse(b.getAttribute('bandwidth') ?? '') ?? 0;
        return bwB.compareTo(bwA);
      });
      final rep = representations.first;

      final codec = rep.getAttribute('codecs') ?? audioAdaptation.getAttribute('codecs');
      final sampleRate = int.tryParse(rep.getAttribute('audioSamplingRate') ?? '');
      final mimeType = rep.getAttribute('mimeType') ?? audioAdaptation.getAttribute('mimeType') ?? 'audio/mp4';

      // Locate SegmentTemplate
      final template = rep.findElements('SegmentTemplate').firstOrNull ??
          audioAdaptation.findElements('SegmentTemplate').firstOrNull;
      if (template == null) return null;

      final initTemplate = template.getAttribute('initialization');
      final mediaTemplate = template.getAttribute('media');
      if (initTemplate == null || mediaTemplate == null) return null;

      final repId = rep.getAttribute('id') ?? '';
      final resolvedInitUrl = _resolveUrl(baseUrl, _substituteVariables(initTemplate, repId: repId));

      final startNumber = int.tryParse(template.getAttribute('startNumber') ?? '1') ?? 1;
      final timescale = int.tryParse(template.getAttribute('timescale') ?? '1') ?? 1;

      final segmentUrls = <String>[];
      final timeline = template.findElements('SegmentTimeline').firstOrNull;

      final bandwidth = int.tryParse(rep.getAttribute('bandwidth') ?? '') ??
          int.tryParse(audioAdaptation.getAttribute('bandwidth') ?? '');
      double? durationSeconds;

      if (timeline != null) {
        var currentNumber = startNumber;
        var currentTime = 0;

        for (final s in timeline.findElements('S')) {
          final tAttr = s.getAttribute('t');
          if (tAttr != null) {
            currentTime = int.tryParse(tAttr) ?? currentTime;
          }
          final d = int.tryParse(s.getAttribute('d') ?? '0') ?? 0;
          final r = int.tryParse(s.getAttribute('r') ?? '0') ?? 0;
          final repeatCount = r < 0 ? 0 : r;

          for (var repeat = 0; repeat <= repeatCount; repeat++) {
            final mediaUrl = _substituteVariables(
              mediaTemplate,
              repId: repId,
              number: currentNumber,
              time: currentTime,
            );
            segmentUrls.add(_resolveUrl(baseUrl, mediaUrl));
            currentNumber++;
            currentTime += d;
          }
        }
        if (currentTime > 0 && timescale > 0) {
          durationSeconds = currentTime / timescale;
        }
      } else {
        // Fallback: duration-based segments if SegmentTimeline is absent
        final durationVal = int.tryParse(template.getAttribute('duration') ?? '');
        if (durationVal != null && durationVal > 0) {
          final totalSec = _parseDuration(mpd.getAttribute('mediaPresentationDuration'));
          if (totalSec != null) {
            durationSeconds = totalSec;
            final totalSegments = ((totalSec * timescale) / durationVal).ceil();
            for (var num = startNumber; num < startNumber + totalSegments; num++) {
              final mediaUrl = _substituteVariables(
                mediaTemplate,
                repId: repId,
                number: num,
              );
              segmentUrls.add(_resolveUrl(baseUrl, mediaUrl));
            }
          }
        }
      }

      durationSeconds ??= _parseDuration(mpd.getAttribute('mediaPresentationDuration'));

      if (segmentUrls.isEmpty) return null;

      return DashTrackInfo(
        codec: codec,
        sampleRate: sampleRate,
        bitDepth: 24, // TIDAL Hi-Res DASH fMP4 FLAC is 24-bit master quality
        initializationUrl: resolvedInitUrl,
        segmentUrls: segmentUrls,
        mimeType: mimeType,
        bandwidth: bandwidth,
        durationSeconds: durationSeconds,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _findBaseUrl(XmlDocument doc) {
    final baseElem = doc.findAllElements('BaseURL').firstOrNull;
    final text = baseElem?.innerText.trim();
    if (text != null && text.isNotEmpty) return text;
    return null;
  }

  static String _resolveUrl(String? baseUrl, String relativeOrAbsolute) {
    if (relativeOrAbsolute.startsWith('http://') || relativeOrAbsolute.startsWith('https://')) {
      return relativeOrAbsolute;
    }
    if (baseUrl != null && baseUrl.isNotEmpty) {
      if (baseUrl.endsWith('/') && relativeOrAbsolute.startsWith('/')) {
        return baseUrl + relativeOrAbsolute.substring(1);
      } else if (!baseUrl.endsWith('/') && !relativeOrAbsolute.startsWith('/')) {
        return '$baseUrl/$relativeOrAbsolute';
      }
      return baseUrl + relativeOrAbsolute;
    }
    return relativeOrAbsolute;
  }

  static String _substituteVariables(
    String template, {
    String? repId,
    int? number,
    int? time,
  }) {
    var result = template;
    if (repId != null) {
      result = result.replaceAll(r'$RepresentationID$', repId);
    }
    if (number != null) {
      final numberRegex = RegExp(r'\$Number(%0([0-9]+)d)?\$');
      result = result.replaceAllMapped(numberRegex, (match) {
        final widthStr = match.group(2);
        if (widthStr != null) {
          final width = int.parse(widthStr);
          return number.toString().padLeft(width, '0');
        }
        return number.toString();
      });
    }
    if (time != null) {
      final timeRegex = RegExp(r'\$Time(%0([0-9]+)d)?\$');
      result = result.replaceAllMapped(timeRegex, (match) {
        final widthStr = match.group(2);
        if (widthStr != null) {
          final width = int.parse(widthStr);
          return time.toString().padLeft(width, '0');
        }
        return time.toString();
      });
    }
    return result;
  }

  static double? _parseDuration(String? isoDuration) {
    if (isoDuration == null || !isoDuration.startsWith('P')) return null;
    final regex = RegExp(r'PT(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9.]+)S)?');
    final match = regex.firstMatch(isoDuration);
    if (match == null) return null;
    final hours = double.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = double.tryParse(match.group(2) ?? '0') ?? 0;
    final seconds = double.tryParse(match.group(3) ?? '0') ?? 0;
    return hours * 3600 + minutes * 60 + seconds;
  }
}
