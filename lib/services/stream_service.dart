import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_model.dart';

/// ── StreamService ─────────────────────────────────────────────────────────
///
/// Fetches candidate streams from Torrentio and a small set of reliable
/// embed fallbacks. Each non-embed TorrentStream now carries a magnetLink
/// so DebridResolverScreen can forward it straight to the debrid bot.
///
/// Removed:
///   • Dead/unreliable embed sources (NontonGo, SmashyStream, 2Embed,
///     AutoEmbed, SuperEmbed) — reduced embed list to 3 proven sources.
///   • torrentio_service.dart duplicate — call getAllStreams() directly.
///   • inflex_resolver_service.dart — replaced by debrid_service.dart.

class StreamService {
  static final _client = http.Client();

  // Public trackers appended to every magnet we build.
  //
  // Was UDP-only (including udp://9.rarbg.com:2810 — RARBG shut down in
  // 2023, that tracker's been dead for two years). DHT peer discovery is
  // also UDP, so on any network that blocks/throttles outbound UDP
  // (common on mobile carriers and restrictive Wi-Fi, often silently),
  // DHT *and* every tracker here failed together — no way to ever get
  // metadata, on any torrent. HTTP(S) trackers run over plain TCP 80/443,
  // same as normal web traffic, so they're the fallback that actually
  // gets through when UDP doesn't.
  static const _trackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.tracker.cl:1337/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'udp://exodus.desync.com:6969/announce',
    'http://tracker.opentrackr.org:1337/announce',
    'https://tracker.tamersunion.org:443/announce',
    'https://tracker.gbitt.info:443/announce',
    'http://open.acgnxtracker.com:80/announce',
  ];

  // ── MAIN ENTRY POINT ──────────────────────────────────────────────────────
  static Future<List<TorrentStream>> getAllStreams({
    required int tmdbId,
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final List<TorrentStream> all = [];

    final results = await Future.wait([
      _getTorrentioStreams(
          imdbId: imdbId, type: type, season: season, episode: episode),
      _getEmbedStreams(
          tmdbId: tmdbId,
          imdbId: imdbId,
          type: type,
          season: season,
          episode: episode),
    ]);

    for (final list in results) {
      all.addAll(list);
    }

    // Debrid sources first (best quality), then embeds
    all.sort((a, b) {
      if (a.isEmbed != b.isEmbed) return a.isEmbed ? 1 : -1;
      return _priority(b.quality).compareTo(_priority(a.quality));
    });

    debugPrint('[StreamService] Total streams: ${all.length} '
        '(${all.where((s) => !s.isEmbed).length} debrid, '
        '${all.where((s) => s.isEmbed).length} embed)');
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

      // qualityfilter excludes cam/scr/480p — keeps only watchable quality
      const filter = 'sort=qualitysize|qualityfilter=480p,scr,cam';
      final url =
          'https://torrentio.strem.fun/$filter/stream/$stremioType/$id.json';
      debugPrint('[StreamService] Torrentio → $url');

      final res = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'InFlex/1.0 Flutter',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        debugPrint('[StreamService] Torrentio ${res.statusCode}');
        return [];
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final streams = (data['streams'] as List?) ?? [];
      debugPrint('[StreamService] Torrentio raw: ${streams.length}');

      final List<TorrentStream> result = [];
      for (final s in streams) {
        if (s['infoHash'] == null) continue;

        final infoHash = s['infoHash'] as String;
        final fileIdx = s['fileIdx'] as int? ?? 0;
        final name = s['name'] as String? ?? '';
        final titleStr = s['title'] as String? ?? '';

        final quality = _detectQuality(name);

        final sizeMatch = RegExp(r'💾\s*([\d.,]+\s*\w+)').firstMatch(titleStr);
        final size = sizeMatch?.group(1);

        final seedMatch = RegExp(r'👤\s*(\d+)').firstMatch(titleStr);
        final seeds =
            seedMatch != null ? int.tryParse(seedMatch.group(1)!) : null;

        // Build magnet URI — used by DebridResolverScreen
        final magnet = _buildMagnet(infoHash,
            title: name.split('\n').first.trim());

        result.add(TorrentStream(
          title: name.split('\n').first.trim(),
          infoHash: infoHash,
          fileIdx: fileIdx,
          quality: quality,
          size: size,
          seeds: seeds,
          // streamUrl kept for reference; actual play goes via Telegram
          streamUrl:
              'https://torrentio.strem.fun/$infoHash/$fileIdx/download.mp4',
          source: 'Torrentio',
          isEmbed: false,
          magnetLink: magnet,
        ));
      }
      return result;
    } catch (e) {
      debugPrint('[StreamService] Torrentio error: $e');
      return [];
    }
  }

  // ── EMBED FALLBACKS ────────────────────────────────────────────────────────
  // Trimmed to 3 sources that are consistently alive and work in WebView.
  static Future<List<TorrentStream>> _getEmbedStreams({
    required int tmdbId,
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    try {
      final List<Map<String, dynamic>> sources = [];

      if (type == 'movie') {
        sources.addAll([
          {
            'name': 'VidSrc Pro',
            'url': 'https://vidsrc.pro/embed/movie/$imdbId',
            'q': '1080p'
          },
          {
            'name': 'VidSrc.to',
            'url': 'https://vidsrc.to/embed/movie/$imdbId',
            'q': '1080p'
          },
          {
            'name': 'VidSrc CC',
            'url': 'https://vidsrc.cc/v2/embed/movie/$imdbId',
            'q': '1080p'
          },
        ]);
      } else {
        final s = season ?? 1;
        final e = episode ?? 1;
        sources.addAll([
          {
            'name': 'VidSrc Pro',
            'url': 'https://vidsrc.pro/embed/tv/$imdbId/$s/$e',
            'q': '1080p'
          },
          {
            'name': 'VidSrc.to',
            'url': 'https://vidsrc.to/embed/tv/$imdbId/$s/$e',
            'q': '1080p'
          },
          {
            'name': 'VidSrc CC',
            'url': 'https://vidsrc.cc/v2/embed/tv/$imdbId/$s/$e',
            'q': '1080p'
          },
        ]);
      }

      return sources
          .map((src) => TorrentStream(
                title: src['name'] as String,
                infoHash: '',
                quality: src['q'] as String,
                streamUrl: src['url'] as String,
                source: src['name'] as String,
                isEmbed: true,
              ))
          .toList();
    } catch (e) {
      debugPrint('[StreamService] embed error: $e');
      return [];
    }
  }

  // ── MAGNET BUILDER ─────────────────────────────────────────────────────────
  static String _buildMagnet(String infoHash, {String? title}) {
    final tr = _trackers
        .map((t) => 'tr=${Uri.encodeComponent(t)}')
        .join('&');
    final dn =
        title != null ? '&dn=${Uri.encodeComponent(title)}' : '';
    return 'magnet:?xt=urn:btih:$infoHash$dn&$tr';
  }

  // ── HELPERS ───────────────────────────────────────────────────────────────
  static String _detectQuality(String name) {
    final n = name.toUpperCase();
    if (n.contains('2160') || n.contains('4K')) return '4K';
    if (n.contains('HDR')) return 'HDR';
    if (n.contains('BLURAY') || n.contains('BLU-RAY') || n.contains('BDRIP'))
      return '1080p BluRay';
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
