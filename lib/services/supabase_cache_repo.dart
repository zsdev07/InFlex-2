import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

/// ── Supabase Cache Repository ─────────────────────────────────────────────
///
/// Manages the `telegram_cache` table in Supabase.
///
/// SQL to create the table (run once in the Supabase SQL editor):
/// ─────────────────────────────────────────────────────────────────────────
/// create table public.telegram_cache (
///   id            uuid primary key default gen_random_uuid(),
///   imdb_id       text not null,
///   quality       text not null default 'HD',
///   magnet_link   text not null,
///   info_hash     text not null,
///   file_id       text,                     -- Telegram file_id, null while leeching
///   file_size     bigint,                   -- bytes
///   status        text not null default 'queued',
///                                           -- queued | downloading | uploading | cached | error
///   progress      int not null default 0,   -- 0–100
///   downloaded_mb float not null default 0,
///   total_mb      float not null default 0,
///   error_msg     text,
///   created_at    timestamptz default now(),
///   updated_at    timestamptz default now()
/// );
///
/// -- Index for fast lookup by imdb_id
/// create index on public.telegram_cache (imdb_id, quality);
///
/// -- RLS: allow read for everyone, write for service_role only
/// alter table public.telegram_cache enable row level security;
/// create policy "public read" on public.telegram_cache
///   for select using (true);
/// ─────────────────────────────────────────────────────────────────────────
///
/// Initialise Supabase in main.dart BEFORE runApp():
///   await Supabase.initialize(
///     url: 'https://YOUR-PROJECT.supabase.co',
///     anonKey: 'YOUR-ANON-KEY',
///   );

class SupabaseCacheRepo {
  static SupabaseClient get _db => Supabase.instance.client;
  static const _table = 'telegram_cache';

  // ── READ: check if a movie is cached ──────────────────────────────────────

  /// Returns the cache row if found, otherwise null.
  static Future<CacheRow?> findByImdbId(String imdbId,
      {String? quality}) async {
    try {
      var query =
          _db.from(_table).select().eq('imdb_id', imdbId);
      if (quality != null) query = query.eq('quality', quality);

      final rows = await query
          .order('created_at', ascending: false)
          .limit(1);

      if (rows.isEmpty) return null;
      return CacheRow.fromJson(rows.first as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[Supabase] findByImdbId error: $e');
      return null;
    }
  }

  /// Returns ALL cached rows for an imdb_id (all qualities).
  static Future<List<CacheRow>> findAllByImdbId(String imdbId) async {
  try {
    final rows = await _db
        .from(_table)
        .select()
        .eq('imdb_id', imdbId)
        .eq('status', 'cached')
        .order('created_at', ascending: false);

    return rows
        .map((r) => CacheRow.fromJson(r as Map<String, dynamic>))
        .toList();
  } catch (e) {
    debugPrint('[Supabase] findAllByImdbId error: $e');
    return [];
   }
 }

  /// Quick boolean check — true if status='cached' and file_id is set.
  static Future<bool> isCached(String imdbId, {String? quality}) async {
    final row = await findByImdbId(imdbId, quality: quality);
    return row?.isCached ?? false;
  }

  // ── WRITE: insert / update ─────────────────────────────────────────────────

  /// Upsert a new leech job. Called when the debrid bot accepts the magnet.
  static Future<void> upsertJob({
    required String imdbId,
    required String magnetLink,
    required String infoHash,
    String quality = 'HD',
    String status = 'queued',
  }) async {
    try {
      await _db.from(_table).upsert({
        'imdb_id': imdbId,
        'magnet_link': magnetLink,
        'info_hash': infoHash,
        'quality': quality,
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'imdb_id,quality');
    } catch (e) {
      debugPrint('[Supabase] upsertJob error: $e');
    }
  }

  /// Update progress for an active download.
  static Future<void> updateProgress({
    required String imdbId,
    required String quality,
    required String status,
    int progress = 0,
    double downloadedMb = 0,
    double totalMb = 0,
  }) async {
    try {
      await _db
          .from(_table)
          .update({
            'status': status,
            'progress': progress,
            'downloaded_mb': downloadedMb,
            'total_mb': totalMb,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('imdb_id', imdbId)
          .eq('quality', quality);
    } catch (e) {
      debugPrint('[Supabase] updateProgress error: $e');
    }
  }

  /// Mark a job as fully cached after the bot uploads to Telegram.
  static Future<void> markCached({
    required String imdbId,
    required String quality,
    required String fileId,
    int? fileSizeBytes,
  }) async {
    try {
      await _db
          .from(_table)
          .update({
            'status': 'cached',
            'file_id': fileId,
            'file_size': fileSizeBytes,
            'progress': 100,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('imdb_id', imdbId)
          .eq('quality', quality);
    } catch (e) {
      debugPrint('[Supabase] markCached error: $e');
    }
  }

  /// Mark a job as errored.
  static Future<void> markError({
    required String imdbId,
    required String quality,
    required String errorMsg,
  }) async {
    try {
      await _db
          .from(_table)
          .update({
            'status': 'error',
            'error_msg': errorMsg,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('imdb_id', imdbId)
          .eq('quality', quality);
    } catch (e) {
      debugPrint('[Supabase] markError error: $e');
    }
  }

  // ── REALTIME (optional) ────────────────────────────────────────────────────

  /// Subscribe to live updates for a specific imdb_id.
  /// Call cancel() on the returned channel when done.
  static RealtimeChannel subscribeToJob({
    required String imdbId,
    required String quality,
    required void Function(CacheRow row) onUpdate,
  }) {
    final channel = _db
        .channel('cache:$imdbId:$quality')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: _table,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'imdb_id',
            value: imdbId,
          ),
          callback: (payload) {
            final row =
                CacheRow.fromJson(payload.newRecord);
            onUpdate(row);
          },
        )
        .subscribe();
    return channel;
  }
}

// ── DATA MODEL ────────────────────────────────────────────────────────────────

enum CacheStatus { queued, downloading, uploading, cached, error, unknown }

class CacheRow {
  final String id;
  final String imdbId;
  final String quality;
  final String magnetLink;
  final String infoHash;
  final String? fileId;
  final int? fileSizeBytes;
  final CacheStatus status;
  final int progress;
  final double downloadedMb;
  final double totalMb;
  final String? errorMsg;
  final DateTime createdAt;
  final DateTime updatedAt;

  CacheRow({
    required this.id,
    required this.imdbId,
    required this.quality,
    required this.magnetLink,
    required this.infoHash,
    this.fileId,
    this.fileSizeBytes,
    required this.status,
    required this.progress,
    required this.downloadedMb,
    required this.totalMb,
    this.errorMsg,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isCached => status == CacheStatus.cached && fileId != null;
  bool get isInProgress =>
      status == CacheStatus.queued ||
      status == CacheStatus.downloading ||
      status == CacheStatus.uploading;

  factory CacheRow.fromJson(Map<String, dynamic> j) {
    return CacheRow(
      id: j['id'] as String? ?? '',
      imdbId: j['imdb_id'] as String? ?? '',
      quality: j['quality'] as String? ?? 'HD',
      magnetLink: j['magnet_link'] as String? ?? '',
      infoHash: j['info_hash'] as String? ?? '',
      fileId: j['file_id'] as String?,
      fileSizeBytes: (j['file_size'] as num?)?.toInt(),
      status: _parseStatus(j['status'] as String?),
      progress: (j['progress'] as num?)?.toInt() ?? 0,
      downloadedMb: (j['downloaded_mb'] as num?)?.toDouble() ?? 0,
      totalMb: (j['total_mb'] as num?)?.toDouble() ?? 0,
      errorMsg: j['error_msg'] as String?,
      createdAt: j['created_at'] != null
          ? DateTime.parse(j['created_at'] as String)
          : DateTime.now(),
      updatedAt: j['updated_at'] != null
          ? DateTime.parse(j['updated_at'] as String)
          : DateTime.now(),
    );
  }

  static CacheStatus _parseStatus(String? s) {
    switch (s) {
      case 'queued':
        return CacheStatus.queued;
      case 'downloading':
        return CacheStatus.downloading;
      case 'uploading':
        return CacheStatus.uploading;
      case 'cached':
        return CacheStatus.cached;
      case 'error':
        return CacheStatus.error;
      default:
        return CacheStatus.unknown;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'imdb_id': imdbId,
        'quality': quality,
        'magnet_link': magnetLink,
        'info_hash': infoHash,
        'file_id': fileId,
        'file_size': fileSizeBytes,
        'status': status.name,
        'progress': progress,
        'downloaded_mb': downloadedMb,
        'total_mb': totalMb,
        'error_msg': errorMsg,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
