import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_model.dart';
import 'release_parser.dart';

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
  // UDP trackers use the same protocol as DHT peer discovery, so on any
  // network that blocks/throttles outbound UDP (common on mobile carriers
  // and restrictive Wi-Fi, often silently), DHT *and* every UDP tracker
  // here fail together - no way to ever get metadata, on any torrent.
  // HTTP trackers run over plain TCP 80, same as normal web traffic, so
  // they're the fallback that actually gets through when UDP doesn't.
  //
  // NOTE: no https:// entries. InTorrent's libtorrent build has no TLS
  // (see native/src/intorrent.cpp's TORRENT_USE_LIBCRYPTO=0) - an https
  // tracker isn't slow here, it's a guaranteed failure every single
  // announce. The two that used to be here (tamersunion, gbitt) never
  // worked for that reason and were pure dead weight.
  //
  // List refreshed from ngosang/trackerslist's "trackers_best" (a
  // continuously-updated, machine-checked list of working public
  // trackers: https://github.com/ngosang/trackerslist) - re-pull that if
  // this list goes stale again; trackers rot over a matter of months.
  static const _trackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.theoks.net:6969/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker-udp.gbitt.info:80/announce',
    'http://tracker.dler.com:6969/announce',
    'http://tracker.renfei.net:8080/announce',
  ];


  // ── MAIN ENTRY POINT ──────────────────────────────────────────────────────
  static Future<List<TorrentStream>> getAllStreams({
    required int tmdbId,
    required String imdbId,
    required String type,
    int? season,
    int? episode,
    String? movieTitle,
  }) async {
    final List<TorrentStream> all = [];

    final results = await Future.wait([
      _getTorrentioStreams(
          imdbId: imdbId,
          type: type,
          season: season,
          episode: episode,
          movieTitle: movieTitle),
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

    // A specific episode can come back with zero torrent results even when
    // plenty exist for the show, usually because: (a) that episode's own
    // release never got indexed as a standalone torrent - common for
    // anime, where releases are whole-season batches - or (b) TMDB lists
    // an episode (a recap, a special) that was never released as its own
    // torrent at all. Either way, retry once asking Torrentio about the
    // season generally (episode 1, which reliably surfaces season packs)
    // and let the engine's own file matching find this episode inside
    // them - see the packFallback note on _getTorrentioStreams.
    final hasTorrents = all.any((s) => !s.isEmbed);
    if (!hasTorrents && type == 'tv' && season != null && episode != null) {
      debugPrint('[StreamService] no direct results for S${season}E$episode '
          '- retrying as a season-pack search');
      final packs = await _getTorrentioStreams(
        imdbId: imdbId,
        type: type,
        season: season,
        movieTitle: movieTitle,
        packFallback: true,
      );
      all.addAll(packs);
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
  //
  // [packFallback]: true when this call is a RETRY after the real episode
  // query came back empty (see getAllStreams). Torrentio resolves fileIdx/
  // fileName for the episode actually asked for, so when we instead ask it
  // for episode 1 just to surface whatever season packs it knows about,
  // those two fields describe episode 1's file - not the one the person
  // wants. They're dropped (left null) below so the caller never acts on a
  // wrong-episode fileIdx; torrent_engine.dart's own file-name matching
  // (which works from the actual torrent's file list, independent of
  // anything Torrentio said) is what finds the right file once the person
  // picks one of these.
  static Future<List<TorrentStream>> _getTorrentioStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
    String? movieTitle,
    bool packFallback = false,
  }) async {
    try {
      final stremioType = type == 'tv' ? 'series' : 'movie';
      String id = imdbId;
      if (type == 'tv') {
        final s = season ?? 1;
        final e = packFallback ? 1 : (episode ?? 1);
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
        // fileIdx is the video's index inside the torrent. When Torrentio
        // omits it the largest file is meant - keep that as null instead of
        // pretending it is file 0.
        final fileIdx = (s['fileIdx'] as num?)?.toInt();
        final name = s['name'] as String? ?? '';
        final titleStr = s['title'] as String? ?? '';

        // Torrentio layout:
        //   name  = "Torrentio\n1080p"                     (addon + quality)
        //   title = "<release name>\n"
        //           "[<file name inside the pack>\n]"       (packs only)
        //           "👤 <seeds> 💾 <size> ⚙️ <indexer>\n"
        //           "<language flags>"
        // The old code used the FIRST LINE OF `name`, i.e. the literal word
        // "Torrentio", as every source's title.
        final lines = titleStr
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        final statIdx =
            lines.indexWhere((l) => l.contains('👤') || l.contains('💾'));
        final statLine = statIdx >= 0 ? lines[statIdx] : titleStr;
        final releaseTitle =
            lines.isNotEmpty ? lines.first : name.split('\n').first.trim();
        final fileLine = statIdx > 1 ? lines[1] : null;
        final languageLine = (statIdx >= 0 && statIdx + 1 < lines.length)
            ? lines.sublist(statIdx + 1).join(' ')
            : '';

        String? hintFile;
        final hints = s['behaviorHints'];
        if (hints is Map) {
          final f = hints['filename'];
          if (f is String && f.trim().isNotEmpty) hintFile = f.trim();
        }
        final fileName = hintFile ?? fileLine;

        final quality = _detectQuality(name);

        final sizeMatch =
            RegExp(r'💾\s*([\d.,]+\s*\w+)').firstMatch(statLine);
        final size = sizeMatch?.group(1);

        final seedMatch = RegExp(r'👤\s*(\d+)').firstMatch(statLine);
        final seeds =
            seedMatch != null ? int.tryParse(seedMatch.group(1)!) : null;

        final provider =
            RegExp(r'\u2699\uFE0F?\s*(.+)$').firstMatch(statLine)?.group(1)?.trim();

        final info = ReleaseInfo.parse(
          releaseTitle: releaseTitle,
          fileName: fileName,
          languageLine: languageLine,
          movieTitle: movieTitle,
        );

        // Build magnet URI — used by DebridResolverScreen and the P2P engine
        final magnet = _buildMagnet(infoHash, title: releaseTitle);

        result.add(TorrentStream(
          title: releaseTitle,
          infoHash: infoHash,
          fileIdx: packFallback ? null : fileIdx,
          quality: quality,
          size: size,
          sizeBytes: parseSizeToBytes(size),
          seeds: seeds,
          // streamUrl kept for reference; actual play goes via Telegram
          streamUrl:
              'https://torrentio.strem.fun/$infoHash/${fileIdx ?? 0}/download.mp4',
          source: 'Torrentio',
          isEmbed: false,
          magnetLink: magnet,
          fileName: packFallback ? null : fileName,
          provider: provider,
          info: info,
          isPackFallback: packFallback,
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
