import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_model.dart';

class StreamService {
  static final _client = http.Client();

  // ── MAIN ENTRY POINT ──────────────────────────────────────────────────────
  static Future<List<TorrentStream>> getAllStreams({
    required int tmdbId,
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final List<TorrentStream> all = [];

    // Run all sources in parallel
    final results = await Future.wait([
      _getTorrentioStreams(imdbId: imdbId, type: type, season: season, episode: episode),
      _getVidsrcStreams(tmdbId: tmdbId, imdbId: imdbId, type: type, season: season, episode: episode),
    ]);

    for (final list in results) {
      all.addAll(list);
    }

    // Best quality first
    all.sort((a, b) => _priority(b.quality).compareTo(_priority(a.quality)));
    debugPrint('[InFlex] Total streams found: ${all.length}');
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
      final stremioType = type == 'tv' ? 'series' : 'movie';
      String id = imdbId;
      if (type == 'tv') {
        final s = season ?? 1;
        final e = episode ?? 1;
        id = '$imdbId:$s:$e';
      }

      final url = 'https://torrentio.strem.fun/sort=qualitysize|qualityfilter=480p,scr,cam/stream/$stremioType/$id.json';
      debugPrint('[InFlex] Torrentio URL: $url');

      final res = await _client.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        debugPrint('[InFlex] Torrentio status: ${res.statusCode}');
        return [];
      }

      final data = jsonDecode(res.body);
      final streams = (data['streams'] as List?) ?? [];
      debugPrint('[InFlex] Torrentio streams: ${streams.length}');

      final List<TorrentStream> result = [];
      for (final s in streams) {
        if (s['infoHash'] == null) continue;
        final infoHash = s['infoHash'] as String;
        final fileIdx = s['fileIdx'] as int? ?? 0;
        final name = s['name'] as String? ?? '';
        final title = s['title'] as String? ?? '';

        // Quality detection
        final q = _detectQuality(name);

        // Size detection
        final sizeMatch = RegExp(r'💾\s*([\d.,]+\s*\w+)').firstMatch(title);
        final size = sizeMatch?.group(1);

        // Seeds detection
        final seedMatch = RegExp(r'👤\s*(\d+)').firstMatch(title);
        final seeds = seedMatch != null ? int.tryParse(seedMatch.group(1)!) : null;

        // Build working stream URL via AllDebrid/Torrentio proxy
        final streamUrl = 'https://torrentio.strem.fun/$infoHash/$fileIdx/download.mp4';

        result.add(TorrentStream(
          title: name.split('\n').first.trim(),
          infoHash: infoHash,
          fileIdx: fileIdx,
          quality: q,
          size: size,
          seeds: seeds,
          streamUrl: streamUrl,
          source: 'Torrentio',
          isEmbed: false,
        ));
      }
      return result;
    } catch (e) {
      debugPrint('[InFlex] Torrentio error: $e');
      return [];
    }
  }

  // ── VIDSRC — accepts both TMDB and IMDB IDs ───────────────────────────────
  static Future<List<TorrentStream>> _getVidsrcStreams({
    required int tmdbId,
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    try {
      final List<TorrentStream> result = [];
      final stremioType = type == 'tv' ? 'tv' : 'movie';

      // Multiple vidsrc endpoints — try all variants
      final List<Map<String, dynamic>> sources = [];

      if (type == 'movie') {
        sources.addAll([
          {'name': 'VidSrc Pro', 'url': 'https://vidsrc.pro/embed/movie/$imdbId', 'q': '1080p'},
          {'name': 'VidSrc.to', 'url': 'https://vidsrc.to/embed/movie/$imdbId', 'q': '1080p'},
          {'name': 'VidSrc.me', 'url': 'https://vidsrc.me/embed/movie?imdb=$imdbId', 'q': '720p'},
          {'name': 'VidSrc CC', 'url': 'https://vidsrc.cc/v2/embed/movie/$imdbId', 'q': '1080p'},
          {'name': 'SuperEmbed', 'url': 'https://multiembed.mov/directstream.php?video_id=$imdbId&tmdb=1', 'q': '1080p'},
          {'name': 'SmashyStream', 'url': 'https://player.smashy.stream/movie/$imdbId', 'q': '1080p'},
          {'name': 'NontonGo', 'url': 'https://www.NontonGo.id/embed/movie/$tmdbId', 'q': '720p'},
          {'name': '2Embed', 'url': 'https://www.2embed.cc/embed/$imdbId', 'q': '720p'},
          {'name': 'AutoEmbed', 'url': 'https://autoembed.cc/embed/movie?id=$imdbId', 'q': '1080p'},
        ]);
      } else {
        final s = season ?? 1;
        final e = episode ?? 1;
        sources.addAll([
          {'name': 'VidSrc Pro', 'url': 'https://vidsrc.pro/embed/tv/$imdbId/$s/$e', 'q': '1080p'},
          {'name': 'VidSrc.to', 'url': 'https://vidsrc.to/embed/tv/$imdbId/$s/$e', 'q': '1080p'},
          {'name': 'VidSrc.me', 'url': 'https://vidsrc.me/embed/tv?imdb=$imdbId&season=$s&episode=$e', 'q': '720p'},
          {'name': 'VidSrc CC', 'url': 'https://vidsrc.cc/v2/embed/tv/$imdbId/$s/$e', 'q': '1080p'},
          {'name': 'SmashyStream', 'url': 'https://player.smashy.stream/tv/$imdbId?s=$s&e=$e', 'q': '1080p'},
          {'name': '2Embed', 'url': 'https://www.2embed.cc/embedtv/$imdbId&s=$s&e=$e', 'q': '720p'},
          {'name': 'AutoEmbed', 'url': 'https://autoembed.cc/embed/tv?id=$imdbId&s=$s&e=$e', 'q': '1080p'},
        ]);
      }

      for (final src in sources) {
        result.add(TorrentStream(
          title: src['name'],
          infoHash: '',
          quality: src['q'],
          streamUrl: src['url'],
          source: src['name'],
          isEmbed: true,
        ));
      }

      return result;
    } catch (e) {
      debugPrint('[InFlex] VidSrc error: $e');
      return [];
    }
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────
  static String _detectQuality(String name) {
    final n = name.toUpperCase();
    if (n.contains('2160') || n.contains('4K')) return '4K';
    if (n.contains('HDR')) return 'HDR';
    if (n.contains('BLURAY') || n.contains('BLU-RAY') || n.contains('BDRIP')) return '1080p BluRay';
    if (n.contains('1080')) return '1080p';
    if (n.contains('720')) return '720p';
    if (n.contains('480')) return '480p';
    return 'HD';
  }

  static int _priority(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K')) return 7;
    if (q.contains('HDR')) return 6;
    if (q.contains('BLURAY') || q.contains('BLU-RAY')) return 5;
    if (q.contains('1080')) return 4;
    if (q.contains('720')) return 3;
    if (q.contains('480')) return 2;
    return 1;
  }

  static int qualityColor(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K') || q.contains('HDR')) return 0xFFa855f7;
    if (q.contains('BLURAY') || q.contains('1080')) return 0xFF3b82f6;
    if (q.contains('720')) return 0xFF22c55e;
    return 0xFF6b7280;
  }
}
