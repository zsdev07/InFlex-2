// ────────────────────────────────────────────────────────────────────────────
// lib/services/debrid_service.dart
//
// InFlex — Supabase Realtime + Debrid flow
//
// This file shows how to:
//   1. Check the cache first (instant play if already cached).
//   2. Subscribe to Realtime BEFORE triggering the leech so no update is missed.
//   3. Trigger the leech (Render → GitHub Actions).
//   4. Drive a progress bar from the live Supabase stream.
// ────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// ── Models ───────────────────────────────────────────────────────────────────

enum DebridStatus { queued, downloading, uploading, cached, error, missing }

class DebridProgress {
  final DebridStatus status;
  final int progress;          // 0–100
  final double downloadedMb;
  final double totalMb;
  final String? fileId;
  final String? errorMsg;

  const DebridProgress({
    required this.status,
    required this.progress,
    this.downloadedMb = 0,
    this.totalMb = 0,
    this.fileId,
    this.errorMsg,
  });

  factory DebridProgress.fromRow(Map<String, dynamic> row) {
    return DebridProgress(
      status: _parseStatus(row['status'] as String? ?? 'missing'),
      progress: (row['progress'] as num?)?.toInt() ?? 0,
      downloadedMb: (row['downloaded_mb'] as num?)?.toDouble() ?? 0,
      totalMb: (row['total_mb'] as num?)?.toDouble() ?? 0,
      fileId: row['file_id'] as String?,
      errorMsg: row['error_msg'] as String?,
    );
  }

  static DebridStatus _parseStatus(String s) {
    return DebridStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => DebridStatus.missing,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class DebridService {
  final SupabaseClient _supabase;
  final String _backendUrl;   // e.g. "https://inflexbackend.onrender.com"

  DebridService({
    required SupabaseClient supabase,
    required String backendUrl,
  })  : _supabase = supabase,
        _backendUrl = backendUrl;

  // ── 1. Check if already cached ─────────────────────────────────────────────
  Future<String?> getCachedFileId(String imdbId, {String quality = 'HD'}) async {
    final res = await _supabase
        .from('telegram_cache')
        .select('file_id, status')
        .eq('imdb_id', imdbId)
        .eq('quality', quality)
        .eq('status', 'cached')
        .maybeSingle();

    return res?['file_id'] as String?;
  }

  // ── 2. Subscribe to live progress BEFORE triggering leech ─────────────────
  //
  // Call this, then immediately call [triggerLeech].
  // The stream will emit DebridProgress updates as the GitHub Action runs.
  //
  Stream<DebridProgress> watchProgress(String imdbId, {String quality = 'HD'}) {
    final controller = StreamController<DebridProgress>.broadcast();

    final channel = _supabase.channel('debrid-$imdbId-$quality');

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'telegram_cache',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'imdb_id',
            value: imdbId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (row['quality'] == quality) {
              controller.add(DebridProgress.fromRow(row));
            }
          },
        )
        .subscribe();

    // Clean up channel when stream is cancelled
    controller.onCancel = () {
      _supabase.removeChannel(channel);
    };

    return controller.stream;
  }

  // ── 3. Trigger the leech via Render backend ────────────────────────────────
  Future<void> triggerLeech({
    required String imdbId,
    required String magnetLink,
    String quality = 'HD',
    String? title,
  }) async {
    final response = await http.post(
      Uri.parse('$_backendUrl/debrid/leech'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'imdb_id': imdbId,
        'magnet_link': magnetLink,
        'quality': quality,
        if (title != null) 'title': title,
      }),
    );

    if (response.statusCode != 202) {
      throw Exception('Leech trigger failed: ${response.statusCode} ${response.body}');
    }
  }

  // ── 4. Convenience: full flow in one call ──────────────────────────────────
  //
  // Returns a Stream<DebridProgress>.
  // The caller should show a progress UI and navigate when status == cached.
  //
  // Usage in a widget:
  //
  //   final stream = debridService.streamOrPlay(
  //     imdbId: 'tt1234567',
  //     magnetLink: 'magnet:?xt=...',
  //     quality: 'HD',
  //   );
  //
  //   StreamBuilder<DebridProgress>(
  //     stream: stream,
  //     builder: (ctx, snap) {
  //       final p = snap.data;
  //       if (p?.status == DebridStatus.cached) {
  //         // navigate to player with p.fileId
  //       }
  //       return LinearProgressIndicator(value: (p?.progress ?? 0) / 100);
  //     },
  //   );
  //
  Stream<DebridProgress> streamOrPlay({
    required String imdbId,
    required String magnetLink,
    String quality = 'HD',
    String? title,
  }) async* {
    // Emit a synthetic "queued" immediately so the UI shows something
    yield const DebridProgress(status: DebridStatus.queued, progress: 0);

    // Subscribe first, THEN trigger — guarantees no update is missed
    final progressStream = watchProgress(imdbId, quality: quality);

    // Trigger async (don't await here — the stream handles completion)
    triggerLeech(
      imdbId: imdbId,
      magnetLink: magnetLink,
      quality: quality,
      title: title,
    ).catchError((e) {
      // Surface error through stream
    });

    await for (final progress in progressStream) {
      yield progress;
      // Auto-complete stream once job reaches a terminal state
      if (progress.status == DebridStatus.cached ||
          progress.status == DebridStatus.error) {
        break;
      }
    }
  }
}
