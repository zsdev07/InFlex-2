import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// ── InFlex Debrid Service ─────────────────────────────────────────────────
///
/// Flow:
///   1. checkCache(imdbId)       → Supabase: does file_id exist?
///   2a. If cached  → buildStreamUrl(fileId) → play instantly
///   2b. If missing → leech(magnetLink)      → bot downloads & uploads to TG
///   3. poll(imdbId) every 5 s  → wait for bot to finish, get file_id
///   4. buildStreamUrl(fileId)  → stream via TG FileStream proxy
///
/// Backend (Render): https://inflexbackend.onrender.com
/// Debrid bot:       banana.fps.ms:10352
/// FileStream proxy: https://YOUR-FILESTREAM-DEPLOY.com   (or self-hosted)

class DebridService {
  // ── CONFIG ─────────────────────────────────────────────────────────────────
  /// Your Render backend. Replace before deploying.
  static const String _backendBase = 'https://inflexbackend.onrender.com';

  /// Telegram FileStream proxy that turns a file_id into a seekable HTTP URL.
  /// Typical deploy: https://github.com/EverythingSuckz/TG-FileStreamBot
  static const String _fileStreamBase = 'https://YOUR-FILESTREAM-DEPLOY.com';

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 20);

  // ── 1. CACHE CHECK ─────────────────────────────────────────────────────────
  /// Returns a [DebridResult] with status=cached and a ready stream URL
  /// if the movie is already on Telegram, otherwise status=missing.
  static Future<DebridResult> checkCache(String imdbId, {String? quality}) async {
    try {
      final uri = Uri.parse('$_backendBase/cache/check').replace(
        queryParameters: {
          'imdb_id': imdbId,
          if (quality != null) 'quality': quality,
        },
      );
      debugPrint('[Debrid] checkCache → $uri');
      final res = await _client.get(uri).timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('[Debrid] checkCache HTTP ${res.statusCode}');
        return DebridResult(status: DebridStatus.missing);
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['cached'] == true && data['file_id'] != null) {
        final streamUrl = buildStreamUrl(data['file_id'] as String);
        return DebridResult(
          status: DebridStatus.cached,
          fileId: data['file_id'] as String,
          streamUrl: streamUrl,
          quality: data['quality'] as String?,
          fileSizeBytes: (data['file_size'] as num?)?.toInt(),
        );
      }

      return DebridResult(status: DebridStatus.missing);
    } catch (e) {
      debugPrint('[Debrid] checkCache error: $e');
      return DebridResult(status: DebridStatus.missing);
    }
  }

  // ── 2. LEECH ───────────────────────────────────────────────────────────────
  /// Sends a magnet link to the backend which forwards it to the debrid bot.
  /// The bot (banana.fps.ms:10352) will torrent → upload chunks to Telegram.
  /// Returns true if the leech job was accepted.
  static Future<bool> leech({
    required String magnetLink,
    required String imdbId,
    String? quality,
    String? title,
  }) async {
    try {
      final uri = Uri.parse('$_backendBase/debrid/leech');
      debugPrint('[Debrid] leech → $uri');
      final res = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'magnet_link': magnetLink,
              'imdb_id': imdbId,
              if (quality != null) 'quality': quality,
              if (title != null) 'title': title,
            }),
          )
          .timeout(_timeout);

      debugPrint('[Debrid] leech response ${res.statusCode}: ${res.body}');
      return res.statusCode == 200 || res.statusCode == 202;
    } catch (e) {
      debugPrint('[Debrid] leech error: $e');
      return false;
    }
  }

  // ── 3. POLL STATUS ─────────────────────────────────────────────────────────
  /// Polls the backend for the leech job status.
  /// Call this every ~5 seconds from a Timer.
  static Future<DebridResult> pollStatus(String imdbId, {String? quality}) async {
    try {
      final uri = Uri.parse('$_backendBase/debrid/status').replace(
        queryParameters: {
          'imdb_id': imdbId,
          if (quality != null) 'quality': quality,
        },
      );
      final res = await _client.get(uri).timeout(_timeout);

      if (res.statusCode != 200) {
        return DebridResult(
          status: DebridStatus.error,
          errorMessage: 'Backend returned ${res.statusCode}',
        );
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final rawStatus = data['status'] as String? ?? 'error';

      switch (rawStatus) {
        case 'cached':
        case 'ready':
          final fileId = data['file_id'] as String?;
          if (fileId == null) {
            return DebridResult(
              status: DebridStatus.error,
              errorMessage: 'Ready but no file_id returned',
            );
          }
          return DebridResult(
            status: DebridStatus.cached,
            fileId: fileId,
            streamUrl: buildStreamUrl(fileId),
            quality: data['quality'] as String?,
            fileSizeBytes: (data['file_size'] as num?)?.toInt(),
          );

        case 'downloading':
          return DebridResult(
            status: DebridStatus.downloading,
            progressPercent: (data['progress'] as num?)?.toInt() ?? 0,
            downloadedMb: (data['downloaded_mb'] as num?)?.toDouble() ?? 0,
            totalMb: (data['total_mb'] as num?)?.toDouble() ?? 0,
            message: data['message'] as String?,
          );

        case 'uploading':
          return DebridResult(
            status: DebridStatus.uploading,
            progressPercent: (data['progress'] as num?)?.toInt() ?? 0,
            message: data['message'] as String? ?? 'Uploading to Telegram...',
          );

        case 'queued':
          return DebridResult(
            status: DebridStatus.queued,
            message: data['message'] as String? ?? 'Queued...',
          );

        default:
          return DebridResult(
            status: DebridStatus.error,
            errorMessage: data['message'] as String? ?? 'Unknown status: $rawStatus',
          );
      }
    } catch (e) {
      debugPrint('[Debrid] pollStatus error: $e');
      return DebridResult(
        status: DebridStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  // ── 4. STREAM URL ──────────────────────────────────────────────────────────
  /// Converts a Telegram file_id to a seekable HTTP stream URL via FileStream.
  /// The FileStream proxy exposes Range-request-compatible endpoints so that
  /// video_player can seek without downloading the whole file.
  static String buildStreamUrl(String fileId) {
    // Standard TG-FileStreamBot route: GET /watch/<file_id>
    return '$_fileStreamBase/watch/$fileId';
  }

  // ── HEALTH ─────────────────────────────────────────────────────────────────
  static Future<bool> isBackendOnline() async {
    try {
      final res = await _client
          .get(Uri.parse('$_backendBase/health'))
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ── RESULT MODEL ──────────────────────────────────────────────────────────────

enum DebridStatus { cached, downloading, uploading, queued, missing, error }

class DebridResult {
  final DebridStatus status;

  // When cached/ready
  final String? fileId;
  final String? streamUrl;
  final String? quality;
  final int? fileSizeBytes;

  // When downloading/uploading
  final int progressPercent;
  final double downloadedMb;
  final double totalMb;
  final String? message;

  // When error
  final String? errorMessage;

  const DebridResult({
    required this.status,
    this.fileId,
    this.streamUrl,
    this.quality,
    this.fileSizeBytes,
    this.progressPercent = 0,
    this.downloadedMb = 0,
    this.totalMb = 0,
    this.message,
    this.errorMessage,
  });

  bool get isCached => status == DebridStatus.cached;
  bool get isError => status == DebridStatus.error;
  bool get isInProgress =>
      status == DebridStatus.downloading ||
      status == DebridStatus.uploading ||
      status == DebridStatus.queued;

  double get progressFraction =>
      progressPercent > 0 ? progressPercent / 100.0 : 0.0;

  String get displayMessage {
    switch (status) {
      case DebridStatus.cached:
        return 'Ready! Starting playback...';
      case DebridStatus.queued:
        return message ?? 'Queued — waiting for debrid bot...';
      case DebridStatus.downloading:
        return message ?? 'Downloading torrent...';
      case DebridStatus.uploading:
        return message ?? 'Uploading to Telegram...';
      case DebridStatus.missing:
        return 'Not cached — starting leech...';
      case DebridStatus.error:
        return errorMessage ?? 'Something went wrong.';
    }
  }
}
