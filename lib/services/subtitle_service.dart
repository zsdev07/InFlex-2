import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ── SubtitleService ───────────────────────────────────────────────────────────
//
// Online ENGLISH subtitles for files that carry none of their own (most
// torrent releases).
//
// Source: the official "OpenSubtitles v3" Stremio addon
// (https://opensubtitles-v3.strem.io/manifest.json - resource `subtitles`,
// types movie/series, ids `tt…`). It speaks the same addon protocol as
// Torrentio, which the app already uses, so an IMDB id is all it needs:
//
//   movie : GET /subtitles/movie/tt1234567.json
//   series: GET /subtitles/series/tt1234567:SEASON:EPISODE.json
//
// The optional "extra" path segment lets the addon find the subtitles that
// match the actual file, and we pass what we know:
//
//   GET /subtitles/movie/tt1234567/videoHash=<hash>&videoSize=<bytes>&filename=<name>.json
//
// `videoHash` is the OpenSubtitles hash of the file (see subtitle_hash.dart) -
// the only way to get the subtitle made for THIS exact release.
//
// Response: {"subtitles":[{"id":"…","url":"https://…srt","lang":"eng"}, …]}.
// We keep only English and only the first few entries (the addon's own
// best-first order).
//
// The official addon can be slow or unavailable at times, so every call has
// a timeout and failures are reported to the caller instead of being hidden.

/// What we know about the video, so the addon can find matching subtitles.
class SubtitleQuery {
  final String imdbId;

  /// 'movie' or 'series' (Stremio's names).
  final String type;
  final int? season;
  final int? episode;

  /// The file that is actually being played (best hint for a matching sub).
  final String? fileName;
  final int? videoSize;

  /// OpenSubtitles hash of the file (16 hex digits), when we could compute it.
  final String? videoHash;

  const SubtitleQuery({
    required this.imdbId,
    required this.type,
    this.season,
    this.episode,
    this.fileName,
    this.videoSize,
    this.videoHash,
  });

  SubtitleQuery withFile({String? fileName, int? videoSize}) => SubtitleQuery(
        imdbId: imdbId,
        type: type,
        season: season,
        episode: episode,
        fileName: fileName ?? this.fileName,
        videoSize: videoSize ?? this.videoSize,
        videoHash: videoHash,
      );

  SubtitleQuery withHash(String hash) => SubtitleQuery(
        imdbId: imdbId,
        type: type,
        season: season,
        episode: episode,
        fileName: fileName,
        videoSize: videoSize,
        videoHash: hash,
      );

  /// Stremio video id: `tt…` for movies, `tt…:season:episode` for episodes.
  String get videoId => (type == 'series' && season != null && episode != null)
      ? '$imdbId:$season:$episode'
      : imdbId;
}

class OnlineSubtitle {
  final String id;
  final String url;
  final String lang;

  const OnlineSubtitle({
    required this.id,
    required this.url,
    required this.lang,
  });
}

class SubtitleService {
  SubtitleService._();

  static const String _base = 'https://opensubtitles-v3.strem.io';
  static final http.Client _client = http.Client();

  /// English subtitles for [query] (at most [max]), best match first.
  /// Returns an empty list when the addon has none; THROWS on network /
  /// server errors so the UI can say "couldn't reach the service" instead of
  /// "no subtitles".
  static Future<List<OnlineSubtitle>> fetchEnglish(
    SubtitleQuery query, {
    int max = 3,
  }) async {
    final extras = <String>[];
    final hash = query.videoHash?.trim();
    if (hash != null && hash.isNotEmpty) extras.add('videoHash=$hash');
    final name = query.fileName?.trim();
    if (name != null && name.isNotEmpty) {
      extras.add('filename=${Uri.encodeComponent(name)}');
    }
    final size = query.videoSize;
    if (size != null && size > 0) extras.add('videoSize=$size');

    final path = '/subtitles/${query.type}/${query.videoId}'
        '${extras.isEmpty ? '' : '/${extras.join('&')}'}.json';
    final uri = Uri.parse('$_base$path');
    debugPrint('[SubtitleService] GET $uri');

    final res = await _client.get(uri, headers: const {
      'accept': 'application/json',
    }).timeout(const Duration(seconds: 12));

    if (res.statusCode != 200) {
      throw Exception('Subtitle service returned ${res.statusCode}');
    }

    final data = jsonDecode(res.body);
    final list = data is Map ? data['subtitles'] : null;
    if (list is! List) return const [];

    final out = <OnlineSubtitle>[];
    final seenUrls = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final lang = (item['lang'] ?? '').toString().toLowerCase().trim();
      if (lang != 'eng' && lang != 'en' && lang != 'english') continue;
      final url = (item['url'] ?? '').toString().trim();
      if (url.isEmpty || !seenUrls.add(url)) continue;
      out.add(OnlineSubtitle(
        id: (item['id'] ?? url).toString(),
        url: url,
        lang: 'eng',
      ));
      if (out.length >= max) break;
    }
    debugPrint('[SubtitleService] ${out.length} English subtitle(s)');
    return out;
  }
}
