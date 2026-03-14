import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/media_model.dart';

class InFlexResolverService {
  static const String base = 'https://zbro7-inflex-resolver.hf.space';
  static final _client = http.Client();

  // ── GET FILTERED STREAMS FROM TORRENTIO VIA RESOLVER ─────────────────────
  static Future<List<TorrentStream>> getStreams({
    required String imdbId,
    required String type,
    int? season,
    int? episode,
  }) async {
    try {
      String url = '$base/streams?imdb_id=$imdbId&media_type=$type';
      if (type == 'tv' && season != null && episode != null) {
        url += '&season=$season&episode=$episode';
      }

      debugPrint('[InFlex] Fetching streams: $url');

      final res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) {
        debugPrint('[InFlex] Streams error: ${res.statusCode}');
        return [];
      }

      final data = jsonDecode(res.body);
      final streams = (data['streams'] as List?) ?? [];
      debugPrint('[InFlex] Got ${streams.length} filtered streams');

      return streams.map((s) => TorrentStream(
        title: s['title'] ?? '',
        infoHash: s['info_hash'] ?? '',
        fileIdx: s['file_idx'] ?? 0,
        quality: s['quality'] ?? 'HD',
        size: s['size_gb'] != null
            ? '${(s['size_gb'] as num).toStringAsFixed(1)} GB'
            : null,
        seeds: s['seeds'] ?? 0,
        streamUrl: '$base/resolve?info_hash=${s['info_hash']}&file_idx=${s['file_idx']}&title=$imdbId',
        source: 'InFlex 🎬',
        isEmbed: false,
      )).toList();
    } catch (e) {
      debugPrint('[InFlex] getStreams error: $e');
      return [];
    }
  }

  // ── RESOLVE A STREAM ──────────────────────────────────────────────────────
  static Future<ResolveResult> resolve({
    required String infoHash,
    int fileIdx = 0,
    String title = '',
  }) async {
    try {
      final url = '$base/resolve?info_hash=$infoHash&file_idx=$fileIdx&title=$title';
      debugPrint('[InFlex] Resolving: $url');

      final res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(res.body);
      final status = data['status'] as String;

      switch (status) {
        case 'ready':
          return ResolveResult(
            status: ResolveStatus.ready,
            streamUrl: '$base${data['stream_url']}',
            cached: data['cached'] ?? false,
            messageId: data['message_id'],
          );
        case 'downloading':
          return ResolveResult(
            status: ResolveStatus.downloading,
            progress: data['progress'] ?? 0,
            message: data['message'] ?? 'Downloading...',
            downloadedMb: (data['downloaded_mb'] ?? 0).toDouble(),
            totalMb: (data['total_mb'] ?? 0).toDouble(),
          );
        case 'queued':
          return ResolveResult(
            status: ResolveStatus.queued,
            message: data['message'] ?? 'Queued...',
          );
        default:
          return ResolveResult(
            status: ResolveStatus.error,
            message: 'Unknown status: $status',
          );
      }
    } catch (e) {
      debugPrint('[InFlex] resolve error: $e');
      return ResolveResult(
        status: ResolveStatus.error,
        message: e.toString(),
      );
    }
  }

  // ── HEALTH CHECK ──────────────────────────────────────────────────────────
  static Future<bool> isOnline() async {
    try {
      final res = await _client
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ── MODELS ────────────────────────────────────────────────────────────────────
enum ResolveStatus { ready, downloading, queued, error }

class ResolveResult {
  final ResolveStatus status;
  final String? streamUrl;
  final bool cached;
  final int? messageId;
  final int progress;
  final String? message;
  final double downloadedMb;
  final double totalMb;

  ResolveResult({
    required this.status,
    this.streamUrl,
    this.cached = false,
    this.messageId,
    this.progress = 0,
    this.message,
    this.downloadedMb = 0,
    this.totalMb = 0,
  });
}
