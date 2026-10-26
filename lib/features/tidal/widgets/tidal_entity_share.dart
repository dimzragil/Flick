import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/utils/error_display.dart';
import '../../../services/sources/tidal_service.dart';

/// Entity types that support sharing via TIDAL detail headers.
enum TidalShareEntityType { album, artist, mix, playlist }

/// Builds the brand-swapped share caption for a TIDAL entity.
///
/// Adopts official TIDAL app share templates observed via static RE:
/// - album: Check out this album on TIDAL: "%1$s" by %2$s %3$s
/// - artist: Check out this artist on TIDAL: %1$s %2$s
/// - mix: Check out this mix on TIDAL: "%1$s" by %2$s %3$s
/// - playlist: Check out this playlist on TIDAL: "%1$s" %2$s
///
/// Brand swap replaces "TIDAL" with "Flick" while preserving punctuation and link tail.
String buildTidalShareCaption({
  required TidalShareEntityType type,
  required String title,
  String? subtitle,
  required String id,
}) {
  final cleanTitle = title.trim().isEmpty ? _defaultTitle(type) : title.trim();
  switch (type) {
    case TidalShareEntityType.album:
      final url = 'https://tidal.com/album/$id';
      if (subtitle != null && subtitle.trim().isNotEmpty) {
        return 'Check out this album on Flick: "$cleanTitle" by ${subtitle.trim()} $url';
      }
      return 'Check out this album on Flick: "$cleanTitle" $url';
    case TidalShareEntityType.artist:
      final url = 'https://tidal.com/artist/$id';
      return 'Check out this artist on Flick: $cleanTitle $url';
    case TidalShareEntityType.mix:
      final url = 'https://tidal.com/mix/$id';
      if (subtitle != null && subtitle.trim().isNotEmpty) {
        return 'Check out this mix on Flick: "$cleanTitle" by ${subtitle.trim()} $url';
      }
      return 'Check out this mix on Flick: "$cleanTitle" $url';
    case TidalShareEntityType.playlist:
      final url = 'https://tidal.com/playlist/$id';
      return 'Check out this playlist on Flick: "$cleanTitle" $url';
  }
}

String _defaultTitle(TidalShareEntityType type) {
  switch (type) {
    case TidalShareEntityType.album:
      return 'Album';
    case TidalShareEntityType.artist:
      return 'Artist';
    case TidalShareEntityType.mix:
      return 'Mix';
    case TidalShareEntityType.playlist:
      return 'Playlist';
  }
}

/// Share card widget for TIDAL entities (Album, Artist, Mix, Playlist).
/// Follows Flick's established share-card aesthetic (4:5 ratio, dominant cover art,
/// typography, bottom dark gradient, Flick SVG watermark).
class TidalEntityShareCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final TidalShareEntityType type;
  final File? imageFile;

  const TidalEntityShareCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.type,
    this.imageFile,
  });

  String get typeLabel {
    switch (type) {
      case TidalShareEntityType.album:
        return 'Album';
      case TidalShareEntityType.artist:
        return 'Artist';
      case TidalShareEntityType.mix:
        return 'Mix';
      case TidalShareEntityType.playlist:
        return 'Playlist';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cleanTitle = title.trim().isEmpty
        ? _defaultTitle(type)
        : title.trim();
    final cleanSubtitle = subtitle?.trim();

    return AspectRatio(
      aspectRatio: 4 / 5,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageFile != null && imageFile!.existsSync())
            Image.file(
              imageFile!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallbackBackground(),
            )
          else
            _fallbackBackground(),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.3, 1.0],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Text(
                  typeLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  cleanTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (cleanSubtitle != null && cleanSubtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    cleanSubtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: SvgPicture.asset(
              'assets/icons/flicklogo_svg.svg',
              width: 56,
              height: 20,
              colorFilter: ColorFilter.mode(
                Colors.white.withValues(alpha: 0.45),
                BlendMode.srcIn,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackBackground() => Container(
    color: const Color(0xFF1A1A1A),
    child: Center(
      child: Icon(
        type == TidalShareEntityType.artist
            ? Icons.person_rounded
            : Icons.album_rounded,
        color: const Color(0xFF404040),
        size: 64,
      ),
    ),
  );
}

/// Captures a widget to PNG bytes by mounting it in the overlay offscreen.
Future<Uint8List?> captureWidgetToPng(
  BuildContext context,
  Widget widget, {
  Duration delay = const Duration(milliseconds: 64),
}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;

  final boundaryKey = GlobalKey();
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      left: -99999,
      top: -99999,
      child: Material(
        type: MaterialType.transparency,
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(width: 300, child: widget),
        ),
      ),
    ),
  );

  overlay.insert(entry);

  try {
    await Future<void>.delayed(delay);
    final boundaryContext = boundaryKey.currentContext;
    if (boundaryContext == null) return null;
    final renderObject = boundaryContext.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;
    final image = await renderObject.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  } finally {
    entry.remove();
  }
}

typedef ShareXFilesAction =
    Future<ShareResult> Function(List<XFile> files, {String? text});

/// Generates a sharing image from the entity's cover art and opens the system share sheet.
Future<void> shareTidalEntity({
  required BuildContext context,
  required TidalShareEntityType type,
  required String id,
  required String title,
  String? subtitle,
  required String? coverUrl,
  ShareXFilesAction? shareXFiles,
  BaseCacheManager? cacheManager,
  Future<Uint8List?> Function(BuildContext context, Widget card)? cardCapturer,
}) async {
  try {
    if (coverUrl == null || coverUrl.trim().isEmpty) {
      throw Exception('No cover art available');
    }

    File? coverFile;

    if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
      final mgr = cacheManager ?? DefaultCacheManager();
      // Per §3.3 / RE findings: TIDAL resolves share art at highest available resolution (1280px).
      final upscaled = TidalService.upscaleCoverUrl(coverUrl, 1280);
      if (upscaled != coverUrl) {
        try {
          final candidate = await mgr.getSingleFile(upscaled);
          if (candidate.existsSync()) {
            coverFile = candidate;
          }
        } catch (_) {
          // Fall back to original coverUrl below.
        }
      }
      coverFile ??= await mgr.getSingleFile(coverUrl);
    } else {
      final rawPath = coverUrl.startsWith('file://')
          ? coverUrl.replaceFirst('file://', '')
          : coverUrl;
      coverFile = File(rawPath);
    }

    if (!coverFile.existsSync()) {
      throw Exception('Cover art file could not be found');
    }

    final card = TidalEntityShareCard(
      title: title,
      subtitle: subtitle,
      type: type,
      imageFile: coverFile,
    );

    final capturer = cardCapturer ?? captureWidgetToPng;
    final bytes = await capturer(context, card);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Failed to generate image');
    }

    final tempDir = Directory.systemTemp;
    final tempFile = File('${tempDir.path}/flick_share_${type.name}_$id.png');
    tempFile.writeAsBytesSync(bytes);

    final caption = buildTidalShareCaption(
      type: type,
      title: title,
      subtitle: subtitle,
      id: id,
    );

    final shareFn = shareXFiles ?? Share.shareXFiles;
    await shareFn([XFile(tempFile.path)], text: caption);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: ${friendlyErrorMessage(e)}')),
      );
    }
  }
}
