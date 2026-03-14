import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import '../models/media_model.dart';

class TorrentioService {
  static const _base = AppConstants.torrentioBase;
  static const _filter = AppConstants.torrentioFilter;

  /// Fetch stream list from Torrentio for a movie or TV episode
  /// [imdbId] — e.g. "tt1234567"
  /// [type]   — "movie" or "series"
  /// [season] / [episode] — for TV only
  static Future<List<TorrentStream>> getStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    String path;
    if (type == 'tv' || type == 'series') {
      final s = season ?? 1;
      final e = episode ?? 1;
      path = '$_base/$_filter/stream/series/$imdbId:$s:$e.json';
    } else {
      path = '$_base/$_filter/stream/movie/$imdbId.json';
    }

    final res = await http.get(Uri.parse(path), headers: {
      'User-Agent': 'InFlex/1.0 Flutter',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('Torrentio returned ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final streams = (data['streams'] as List<dynamic>?) ?? [];

    return streams
        .where((s) => s['infoHash'] != null)
        .map((s) => _parseStream(s))
        .toList();
  }

  static TorrentStream _parseStream(Map<String, dynamic> s) {
    final name = s['name'] as String? ?? '';
    final title = s['title'] as String? ?? '';
    final infoHash = s['infoHash'] as String;
    final fileIdx = s['fileIdx'] as int?;

    // Extract quality from name
    final qualMatch = RegExp(
      r'(4K|2160p|1080p|720p|HDR|BluRay|BDRip|WEB-DL|WEBRip)',
      caseSensitive: false,
    ).firstMatch(name);
    final quality = qualMatch?.group(1) ?? 'HD';

    // Extract size
    final sizeMatch = RegExp(r'💾\s*([\d.]+\s*\w+)').firstMatch(title);
    final size = sizeMatch?.group(1);

    // Build HLS stream URL via Torrentio's WebTorrent proxy
    final streamUrl = '$_base/$infoHash/index.m3u8';

    return TorrentStream(
      title: name.split('\n').first,
      infoHash: infoHash,
      fileIdx: fileIdx,
      quality: quality,
      size: size,
      streamUrl: streamUrl,
    );
  }

  /// Get quality badge color
  static int qualityColor(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K') || q.contains('2160') || q.contains('HDR')) {
      return 0xFFa855f7; // purple
    } else if (q.contains('1080')) {
      return 0xFF3b82f6; // blue
    } else if (q.contains('720')) {
      return 0xFF22c55e; // green
    }
    return 0xFF6b7280; // gray
  }

  /// Quality sort priority (higher = better)
  static int qualityPriority(String quality) {
    final q = quality.toUpperCase();
    if (q.contains('4K') || q.contains('2160')) return 5;
    if (q.contains('HDR')) return 4;
    if (q.contains('1080')) return 3;
    if (q.contains('720')) return 2;
    return 1;
  }

  /// Sort streams best quality first
  static List<TorrentStream> sortByQuality(List<TorrentStream> streams) {
    final sorted = [...streams];
    sorted.sort((a, b) =>
        qualityPriority(b.quality).compareTo(qualityPriority(a.quality)));
    return sorted;
  }
}
