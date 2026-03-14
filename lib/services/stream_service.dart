import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';

class StreamService {
  static final _client = http.Client();

  /// Get ALL streams from ALL sources for a movie/show
  static Future<List<TorrentStream>> getAllStreams({
    required String imdbId,
    required String type, // 'movie' or 'tv'
    int? season,
    int? episode,
  }) async {
    final List<TorrentStream> all = [];

    // Run all sources in parallel
    final results = await Future.wait([
      _getTorrentioStreams(imdbId: imdbId, type: type, season: season, episode: episode),
      _getEmbedSources(imdbId: imdbId, type: type, season: season, episode: episode),
    ]);

    for (final list in results) {
      all.addAll(list);
    }

    // Sort by quality
    all.sort((a, b) => _qualityPriority(b.quality).compareTo(_qualityPriority(a.quality)));
    return all;
  }

  // ── TORRENTIO ─────────────────────────────────────────────────────────────
  static Future<List<TorrentStream>> _getTorrentioStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    try {
      final filter = AppConstants.torrentioFilter;
      final base = AppConstants.torrentioBase;

      String path;
      if (type == 'tv') {
        final s = season ?? 1;
        final e = episode ?? 1;
        path = '$base/$filter/stream/series/$imdbId:$s:$e.json';
      } else {
        path = '$base/$filter/stream/movie/$imdbId.json';
      }

      final res = await _client.get(Uri.parse(path), headers: {
        'User-Agent': 'InFlex/1.0 Flutter',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) return [];

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final streams = (data['streams'] as List<dynamic>?) ?? [];

      return streams
          .where((s) => s['infoHash'] != null)
          .map((s) => _parseTorrentStream(s))
          .toList();
    } catch (e) {
      print('[InFlex] Torrentio error: $e');
      return [];
    }
  }

  static TorrentStream _parseTorrentStream(Map<String, dynamic> s) {
    final name = s['name'] as String? ?? '';
    final title = s['title'] as String? ?? '';
    final infoHash = s['infoHash'] as String;
    final fileIdx = s['fileIdx'] as int?;

    final qualMatch = RegExp(
      r'(4K|2160p|1080p|720p|HDR|BluRay|BDRip|WEB-DL|WEBRip)',
      caseSensitive: false,
    ).firstMatch(name);
    final quality = qualMatch?.group(1) ?? 'HD';

    final sizeMatch = RegExp(r'💾\s*([\d.]+\s*\w+)').firstMatch(title);
    final size = sizeMatch?.group(1);

    // Torrentio stream URL via their proxy
    final idx = fileIdx != null ? '/$fileIdx' : '/0';
    final streamUrl = 'https://torrentio.strem.fun/stream/$infoHash$idx.mp4';

    return TorrentStream(
      title: name.split('\n').first,
      infoHash: infoHash,
      fileIdx: fileIdx,
      quality: quality,
      size: size,
      streamUrl: streamUrl,
      source: 'Torrentio 🧲',
    );
  }

  // ── EMBED SOURCES (vidsrc, autoembed, 2embed) ─────────────────────────────
  static Future<List<TorrentStream>> _getEmbedSources({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final List<TorrentStream> embeds = [];

    final sources = <Map<String, String>>[];

    if (type == 'movie') {
      sources.addAll([
        {
          'name': 'VidSrc',
          'url': '${AppConstants.vidsrcBase}/embed/movie/$imdbId',
          'quality': '1080p',
        },
        {
          'name': 'AutoEmbed',
          'url': '${AppConstants.autoembedBase}/embed/movie?id=$imdbId',
          'quality': '1080p',
        },
        {
          'name': '2Embed',
          'url': '${AppConstants.twoEmbedBase}/embed/&tmdb=$imdbId',
          'quality': '720p',
        },
      ]);
    } else {
      final s = season ?? 1;
      final e = episode ?? 1;
      sources.addAll([
        {
          'name': 'VidSrc',
          'url': '${AppConstants.vidsrcBase}/embed/tv/$imdbId/$s/$e',
          'quality': '1080p',
        },
        {
          'name': 'AutoEmbed',
          'url': '${AppConstants.autoembedBase}/embed/tv?id=$imdbId&s=$s&e=$e',
          'quality': '1080p',
        },
        {
          'name': '2Embed',
          'url': '${AppConstants.twoEmbedBase}/embedtv.php?id=$imdbId&s=$s&e=$e',
          'quality': '720p',
        },
      ]);
    }

    for (final src in sources) {
      embeds.add(TorrentStream(
        title: src['name']!,
        infoHash: '',
        quality: src['quality']!,
        streamUrl: src['url']!,
        source: src['name']!,
        isEmbed: true,
      ));
    }

    return embeds;
  }

  // ── QUALITY HELPERS ───────────────────────────────────────────────────────
  static int _qualityPriority(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K') || q.contains('2160')) return 6;
    if (q.contains('HDR')) return 5;
    if (q.contains('BLURAY') || q.contains('BDRIP')) return 4;
    if (q.contains('1080')) return 3;
    if (q.contains('720')) return 2;
    return 1;
  }

  static int qualityColor(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K') || q.contains('2160') || q.contains('HDR')) return 0xFFa855f7;
    if (q.contains('1080')) return 0xFF3b82f6;
    if (q.contains('720')) return 0xFF22c55e;
    return 0xFF6b7280;
  }
}
