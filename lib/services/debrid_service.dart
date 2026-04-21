// lib/services/debrid_service.dart
//
// InFlex — Debrid Service (Serverless Edition)
// ══════════════════════════════════════════════════════════════════════════════
//
// All methods are STATIC so debrid_resolver_screen.dart can call them as:
//   DebridService.checkCache(...)
//   DebridService.leech(...)
//   DebridService.pollStatus(...)
//
// The stream URL returned in DebridResult.streamUrl points at TGFileStreamBot
// using the new /stream/doc/:docID route (no hash needed).
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:http/http.dart' as http;

// ── Config ────────────────────────────────────────────────────────────────────

/// Your Render backend URL — no trailing slash.
const String _kBackendUrl = 'https://inflexbackend.onrender.com';

/// Your TGFileStreamBot Render URL — no trailing slash.
/// This is the value you provided: https://streambothost.onrender.com
const String _kStreamBotUrl = 'https://streambothost.onrender.com';

// ── DebridStatus ──────────────────────────────────────────────────────────────

enum DebridStatus {
  queued,
  downloading,
  uploading,
  cached,
  error,
  missing;

  static DebridStatus fromString(String? s) {
    switch (s) {
      case 'queued':      return DebridStatus.queued;
      case 'downloading': return DebridStatus.downloading;
      case 'uploading':   return DebridStatus.uploading;
      case 'cached':      return DebridStatus.cached;
      case 'error':       return DebridStatus.error;
      default:            return DebridStatus.missing;
    }
  }
}

// ── DebridResult ──────────────────────────────────────────────────────────────

class DebridResult {
  final DebridStatus status;
  final bool isCached;

  /// Direct stream URL: https://streambothost.onrender.com/stream/doc/<file_id>
  /// Only non-null when isCached == true.
  final String? streamUrl;

  final int progressPercent;
  final double downloadedMb;
  final double totalMb;
  final String displayMessage;

  const DebridResult({
    required this.status,
    required this.isCached,
    this.streamUrl,
    this.progressPercent = 0,
    this.downloadedMb = 0,
    this.totalMb = 0,
    this.displayMessage = '',
  });

  /// Build from GET /cache/check response
  factory DebridResult.fromCacheCheck(Map<String, dynamic> json) {
    final bool cached   = json['cached'] == true;
    final String? fileId = json['file_id'] as String?;
    return DebridResult(
      status:         cached ? DebridStatus.cached : DebridStatus.missing,
      isCached:       cached,
      streamUrl:      (cached && fileId != null)
                          ? '$_kStreamBotUrl/stream/doc/$fileId'
                          : null,
      displayMessage: cached
                          ? 'Already on Telegram — instant play!'
                          : 'Not cached yet.',
    );
  }

  /// Build from GET /debrid/status response
  factory DebridResult.fromStatusPoll(Map<String, dynamic> json) {
    final DebridStatus status  = DebridStatus.fromString(json['status'] as String?);
    final bool isCached        = status == DebridStatus.cached;
    final String? fileId       = json['file_id'] as String?;
    final int progress         = (json['progress'] as num?)?.toInt() ?? 0;
    final double dlMb          = (json['downloaded_mb'] as num?)?.toDouble() ?? 0;
    final double totalMb       = (json['total_mb'] as num?)?.toDouble() ?? 0;
    final String msg           = json['message'] as String? ?? _defaultMessage(status);

    return DebridResult(
      status:          status,
      isCached:        isCached,
      streamUrl:       (isCached && fileId != null)
                           ? '$_kStreamBotUrl/stream/doc/$fileId'
                           : null,
      progressPercent: progress,
      downloadedMb:    dlMb,
      totalMb:         totalMb,
      displayMessage:  msg,
    );
  }

  /// Convenience error result
  factory DebridResult.error([String msg = 'Something went wrong.']) =>
      DebridResult(
        status:         DebridStatus.error,
        isCached:       false,
        displayMessage: msg,
      );

  static String _defaultMessage(DebridStatus s) {
    switch (s) {
      case DebridStatus.queued:      return 'Queued — GitHub worker starting...';
      case DebridStatus.downloading: return 'Downloading torrent chunks...';
      case DebridStatus.uploading:   return 'Uploading to Telegram...';
      case DebridStatus.cached:      return 'Ready! Starting playback...';
      case DebridStatus.error:       return 'Something went wrong.';
      case DebridStatus.missing:     return 'Not found.';
    }
  }
}

// ── DebridService ─────────────────────────────────────────────────────────────

class DebridService {
  // Private constructor — this class is never instantiated.
  // All methods are static, matching how debrid_resolver_screen.dart calls them.
  DebridService._();

  // ── 1. checkCache ──────────────────────────────────────────────────────────
  //
  // Checks Supabase (via Render) for a cached file_id.
  // Returns instantly — no GitHub Action triggered.
  //
  // Called by DebridResolverScreen._start() as the very first step.
  //
  static Future<DebridResult> checkCache(
    String imdbId, {
    String quality = 'HD',
  }) async {
    try {
      final Uri uri = Uri.parse('$_kBackendUrl/cache/check').replace(
        queryParameters: {'imdb_id': imdbId, 'quality': quality},
      );

      final http.Response res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        return DebridResult.fromCacheCheck(
          jsonDecode(res.body) as Map<String, dynamic>,
        );
      }
      return DebridResult.error('Cache check failed (${res.statusCode})');
    } catch (e) {
      return DebridResult.error('Cache check error: $e');
    }
  }

  // ── 2. leech ───────────────────────────────────────────────────────────────
  //
  // Tells the Render backend to:
  //   • Upsert a 'queued' row in Supabase
  //   • Fire a GitHub Actions repository_dispatch
  //
  // Returns true if accepted (HTTP 200 or 202), false on network error.
  //
  // Called by DebridResolverScreen._start() after a cache miss.
  //
  static Future<bool> leech({
    required String magnetLink,
    required String imdbId,
    String quality = 'HD',
    String? title,
  }) async {
    try {
      final http.Response res = await http
          .post(
            Uri.parse('$_kBackendUrl/debrid/leech'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'magnet_link': magnetLink,
              'imdb_id':     imdbId,
              'quality':     quality,
              if (title != null) 'title': title,
            }),
          )
          .timeout(const Duration(seconds: 15));

      // 202 = freshly queued, 200 = already in progress — both mean accepted
      return res.statusCode == 202 || res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── 3. pollStatus ──────────────────────────────────────────────────────────
  //
  // Reads the current job row from Supabase (via Render).
  // Called every 5 s by DebridResolverScreen._poll() until
  // result.isCached == true or status == error.
  //
  static Future<DebridResult> pollStatus(
    String imdbId, {
    String quality = 'HD',
  }) async {
    try {
      final Uri uri = Uri.parse('$_kBackendUrl/debrid/status').replace(
        queryParameters: {'imdb_id': imdbId, 'quality': quality},
      );

      final http.Response res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        return DebridResult.fromStatusPoll(
          jsonDecode(res.body) as Map<String, dynamic>,
        );
      }
      return DebridResult.error('Status poll failed (${res.statusCode})');
    } catch (e) {
      return DebridResult.error('Status poll error: $e');
    }
  }
}
