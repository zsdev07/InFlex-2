import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

// ── TorrentEngine ─────────────────────────────────────────────────────────────
//
// Wraps libtorrent_flutter v1.8.2 to provide sequential P2P playback.
//
// Design:
//   • One active torrent at a time — calling start() cancels any prior session
//   • Downloads into getTemporaryDirectory()/inflex_stream — Android auto-clears
//     this, never touches user-visible storage
//   • Uses LibtorrentFlutter.instance (singleton) — never construct directly
//   • NO localhost HTTP server — media_kit opens the file path directly via
//     Media('file:///...'), eliminating all loopback/port-conflict issues
//   • Auto-deletes downloaded file when stop() is called (player closed)
//   • 500 MB sliding-window cache via maxCacheBytes — libtorrent discards
//     already-played pieces so disk usage never exceeds the limit
//   • Fires TorrentState updates via a Stream for the UI to consume
//
// Usage:
//   final engine = TorrentEngine();
//   engine.stateStream.listen((state) { ... });
//   await engine.start(magnetLink);
//   final path = engine.filePath; // pass as Media('file:///$path')
//   await engine.stop();          // call on dispose — deletes temp file

const int _kReadyThresholdMb = 8;                // MB buffered before playback
const int _kMaxCacheBytes    = 500 * 1024 * 1024; // 500 MB cache cap

enum TorrentPhase {
  idle,
  resolving,  // fetching metadata from DHT
  buffering,  // downloading initial buffer
  ready,      // enough buffered — player can start
  streaming,  // player is playing
  error,
}

class TorrentState {
  final TorrentPhase phase;
  final double downloadSpeedMbs;
  final double progressPercent;
  final double bufferedMb;
  final double totalMb;
  final int peers;
  final String? errorMessage;
  /// Local file path — valid when phase == ready or streaming.
  /// Open with: Media('file:///$filePath')
  final String? filePath;

  const TorrentState({
    required this.phase,
    this.downloadSpeedMbs = 0,
    this.progressPercent = 0,
    this.bufferedMb = 0,
    this.totalMb = 0,
    this.peers = 0,
    this.errorMessage,
    this.filePath,
  });

  TorrentState copyWith({
    TorrentPhase? phase,
    double? downloadSpeedMbs,
    double? progressPercent,
    double? bufferedMb,
    double? totalMb,
    int? peers,
    String? errorMessage,
    String? filePath,
  }) =>
      TorrentState(
        phase: phase ?? this.phase,
        downloadSpeedMbs: downloadSpeedMbs ?? this.downloadSpeedMbs,
        progressPercent: progressPercent ?? this.progressPercent,
        bufferedMb: bufferedMb ?? this.bufferedMb,
        totalMb: totalMb ?? this.totalMb,
        peers: peers ?? this.peers,
        errorMessage: errorMessage ?? this.errorMessage,
        filePath: filePath ?? this.filePath,
      );

  String get displayMessage {
    switch (phase) {
      case TorrentPhase.idle:      return 'Idle';
      case TorrentPhase.resolving: return 'Connecting to peers via DHT...';
      case TorrentPhase.buffering:
        return peers == 0
            ? 'Finding peers...'
            : 'Buffering from $peers peers • ${downloadSpeedMbs.toStringAsFixed(1)} MB/s';
      case TorrentPhase.ready:     return 'Buffer ready — starting player';
      case TorrentPhase.streaming: return 'Streaming • ${downloadSpeedMbs.toStringAsFixed(1)} MB/s';
      case TorrentPhase.error:     return errorMessage ?? 'Stream error';
    }
  }

  bool get canPlay =>
      phase == TorrentPhase.ready || phase == TorrentPhase.streaming;
}

class TorrentEngine {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final TorrentEngine _instance = TorrentEngine._internal();
  factory TorrentEngine() => _instance;
  TorrentEngine._internal();

  // ── Internal state ─────────────────────────────────────────────────────────
  final _engine = LibtorrentFlutter.instance;

  int? _activeTorrentId;
  StreamSubscription<Map<int, TorrentInfo>>? _torrentSub;

  final _stateController = StreamController<TorrentState>.broadcast();
  TorrentState _current = const TorrentState(phase: TorrentPhase.idle);

  Directory? _saveDir;

  // ── Public API ─────────────────────────────────────────────────────────────

  Stream<TorrentState> get stateStream => _stateController.stream;
  TorrentState get currentState => _current;

  /// Local file path — valid when phase == ready or streaming.
  String? get filePath => _current.filePath;

  /// Start a new torrent session. Cancels any prior session first.
  Future<void> start(String magnetLink) async {
    await stop();
    _emit(_current.copyWith(phase: TorrentPhase.resolving));

    try {
      final tempDir = await getTemporaryDirectory();
      _saveDir = Directory('${tempDir.path}/inflex_stream');
      if (!_saveDir!.existsSync()) _saveDir!.createSync(recursive: true);

      await LibtorrentFlutter.init(
        defaultSavePath: _saveDir!.path,
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 500),
        maxCacheBytes: _kMaxCacheBytes,
      );

      _activeTorrentId = _engine.addMagnet(magnetLink);
      _torrentSub = _engine.torrentUpdates.listen(_onTorrentUpdate);

      debugPrint('[TorrentEngine] Session started → torrentId=$_activeTorrentId');
    } catch (e) {
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start torrent: $e',
      ));
    }
  }

  /// Stop session, remove torrent, delete temp files.
  /// Call this when the player closes.
  Future<void> stop() async {
    _torrentSub?.cancel();
    _torrentSub = null;

    if (_activeTorrentId != null) {
      try {
        _engine.removeTorrent(_activeTorrentId!, deleteFiles: true);
      } catch (_) {}
      _activeTorrentId = null;
    }

    _cleanupSaveDir();
    _emit(const TorrentState(phase: TorrentPhase.idle));
    debugPrint('[TorrentEngine] Session stopped — temp files deleted');
  }

  /// Stub — kept for API compatibility.
  // ignore: avoid_returning_null_for_void
  void onPlaybackProgress(Duration position, Duration duration) {}

  void dispose() {
    stop();
    _stateController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onTorrentUpdate(Map<int, TorrentInfo> torrents) {
    if (_activeTorrentId == null) return;
    final t = torrents[_activeTorrentId];
    if (t == null) return;

    final totalMb      = t.totalWanted / (1024 * 1024);
    final downloadedMb = t.totalDone / (1024 * 1024);
    final speedMbs     = t.downloadRate / (1024 * 1024);
    final peers        = t.numPeers;
    final progress     = totalMb > 0 ? (downloadedMb / totalMb) * 100 : 0.0;

    TorrentPhase phase;

    if (!t.hasMetadata) {
      phase = TorrentPhase.resolving;
    } else if (downloadedMb < _kReadyThresholdMb) {
      phase = TorrentPhase.buffering;
    } else if (_current.phase == TorrentPhase.buffering ||
               _current.phase == TorrentPhase.resolving) {
      phase = TorrentPhase.ready;
      _resolveFilePath(t);
    } else {
      phase = TorrentPhase.streaming;
    }

    _emit(_current.copyWith(
      phase: phase,
      downloadSpeedMbs: speedMbs,
      progressPercent: progress.toDouble(),
      bufferedMb: downloadedMb,
      totalMb: totalMb,
      peers: peers,
    ));
  }

  /// Find the largest file in the torrent's save directory (the video file).
  void _resolveFilePath(TorrentInfo t) {
    try {
      final dir = Directory(t.savePath);
      if (!dir.existsSync()) {
        debugPrint('[TorrentEngine] savePath not yet on disk: ${t.savePath}');
        return;
      }

      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .toList()
        ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));

      if (files.isEmpty) {
        debugPrint('[TorrentEngine] No files found in savePath');
        return;
      }

      final videoFile = files.first;
      debugPrint('[TorrentEngine] File path resolved → ${videoFile.path}');
      _emit(_current.copyWith(filePath: videoFile.path));
    } catch (e) {
      debugPrint('[TorrentEngine] _resolveFilePath error: $e');
    }
  }

  void _cleanupSaveDir() {
    try {
      if (_saveDir != null && _saveDir!.existsSync()) {
        _saveDir!.deleteSync(recursive: true);
        debugPrint('[TorrentEngine] Cleaned save dir: ${_saveDir!.path}');
      }
    } catch (e) {
      debugPrint('[TorrentEngine] cleanup error (non-fatal): $e');
    } finally {
      _saveDir = null;
    }
  }

  void _emit(TorrentState state) {
    _current = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }
}
