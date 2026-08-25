import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;
import 'package:path_provider/path_provider.dart';

// ── TorrentEngine ─────────────────────────────────────────────────────────────
//
// Wraps libtorrent_flutter to provide P2P playback.
//
// ── WHY THIS FILE WAS REWRITTEN ─────────────────────────────────────────────
// The previous version called addMagnet() and then read the largest file
// straight off disk via Media('file:///...') once a rough MB threshold was
// hit. That completely bypassed the plugin's actual purpose: it ships a
// TorrServer-style native HTTP server with head+tail preload and a proper
// read-ahead cache — see startStream()/preloadStream() below. Reading a raw,
// partially-downloaded file directly means the player is reading holes
// wherever pieces haven't arrived yet, with zero guarantee the file's index
// (the moov atom, for mp4 — usually the LAST bytes in the file) had
// downloaded. That's why every source, every quality, showed the same blank
// gray screen: mpv opened the file handle fine, but could never actually
// parse or read frames from it.
//
// Fix: use the plugin's own startStream() + preloadStream() APIs. This
// returns an HTTP URL served by the native layer, which correctly blocks on
// reads until the right bytes are in, and preloads the head+tail of the file
// up front so mpv can read the container's index immediately instead of
// waiting for sequential download to crawl all the way there.
//
// Design:
//   • One active torrent at a time — calling start() cancels any prior session
//   • streamOnly: true — only downloads what the reader actually needs,
//     instead of pulling the whole file in the background
//   • Downloads into getTemporaryDirectory()/inflex_stream — Android auto-clears
//     this, never touches user-visible storage
//   • disposeTorrent() on stop() — stops the stream, removes the torrent,
//     and deletes downloaded files in one call
//   • Fires TorrentState updates via a Stream for the UI to consume
//
// Usage:
//   final engine = TorrentEngine();
//   engine.stateStream.listen((state) { ... });
//   await engine.start(magnetLink);
//   final url = engine.streamUrl; // pass straight to Media(url) — it's HTTP
//   await engine.stop();          // call on dispose — deletes temp files

const int _kMaxCacheBytes = 500 * 1024 * 1024; // 500 MB read-ahead cache cap
const int _kPreloadBytes = 16 * 1024 * 1024; // head+tail preload (TorrServer default)

enum TorrentPhase {
  idle,
  resolving, // fetching metadata from DHT
  buffering, // stream preloading / read-ahead filling
  ready, // enough buffered — player can start
  streaming, // player is playing
  error,
}

class TorrentState {
  final TorrentPhase phase;
  final double downloadSpeedMbs;
  final double bufferSeconds;

  /// Buffer fill, 0.0–1.0 (derived from the plugin's read-ahead window).
  final double bufferPct;
  final int peers;
  final String? errorMessage;

  /// HTTP stream URL — valid when phase == ready or streaming.
  /// Open directly with: Media(streamUrl) — no file:// wrapping needed.
  final String? streamUrl;

  const TorrentState({
    required this.phase,
    this.downloadSpeedMbs = 0,
    this.bufferSeconds = 0,
    this.bufferPct = 0,
    this.peers = 0,
    this.errorMessage,
    this.streamUrl,
  });

  TorrentState copyWith({
    TorrentPhase? phase,
    double? downloadSpeedMbs,
    double? bufferSeconds,
    double? bufferPct,
    int? peers,
    String? errorMessage,
    String? streamUrl,
  }) =>
      TorrentState(
        phase: phase ?? this.phase,
        downloadSpeedMbs: downloadSpeedMbs ?? this.downloadSpeedMbs,
        bufferSeconds: bufferSeconds ?? this.bufferSeconds,
        bufferPct: bufferPct ?? this.bufferPct,
        peers: peers ?? this.peers,
        errorMessage: errorMessage ?? this.errorMessage,
        streamUrl: streamUrl ?? this.streamUrl,
      );

  String get displayMessage {
    switch (phase) {
      case TorrentPhase.idle:
        return 'Idle';
      case TorrentPhase.resolving:
        return 'Connecting to peers via DHT...';
      case TorrentPhase.buffering:
        return peers == 0
            ? 'Finding peers...'
            : 'Buffering from $peers peers • ${downloadSpeedMbs.toStringAsFixed(1)} MB/s';
      case TorrentPhase.ready:
        return 'Buffer ready — starting player';
      case TorrentPhase.streaming:
        return 'Streaming • ${downloadSpeedMbs.toStringAsFixed(1)} MB/s';
      case TorrentPhase.error:
        return errorMessage ?? 'Stream error';
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
  int? _activeTorrentId;
  int? _activeStreamId;
  bool _streamStarted = false;

  StreamSubscription<Map<int, lt.TorrentInfo>>? _torrentSub;
  StreamSubscription<Map<int, lt.StreamInfo>>? _streamSub;

  final _stateController = StreamController<TorrentState>.broadcast();
  TorrentState _current = const TorrentState(phase: TorrentPhase.idle);

  Directory? _saveDir;

  // ── Public API ─────────────────────────────────────────────────────────────

  Stream<TorrentState> get stateStream => _stateController.stream;
  TorrentState get currentState => _current;

  /// HTTP stream URL — valid when phase == ready or streaming.
  String? get streamUrl => _current.streamUrl;

  /// Start a new torrent session. Cancels any prior session first.
  Future<void> start(String magnetLink) async {
    await stop();
    _emit(const TorrentState(phase: TorrentPhase.resolving));
    _streamStarted = false;

    try {
      final tempDir = await getTemporaryDirectory();
      _saveDir = Directory('${tempDir.path}/inflex_stream');
      if (!_saveDir!.existsSync()) _saveDir!.createSync(recursive: true);

      if (!lt.LibtorrentFlutter.isInitialized) {
        await lt.LibtorrentFlutter.init(
          defaultSavePath: _saveDir!.path,
          fetchTrackers: true,
          pollInterval: const Duration(milliseconds: 500),
        );
      }

      final engine = lt.LibtorrentFlutter.instance;

      // streamOnly: true — engine fetches only the pieces the reader
      // actually needs instead of downloading the whole file in the
      // background. Matches the "watch now, discard behind" design.
      _activeTorrentId = engine.addMagnet(magnetLink, _saveDir!.path, true);

      _torrentSub = engine.torrentUpdates.listen(_onTorrentUpdate);
      _streamSub = engine.streamUpdates.listen(_onStreamUpdate);

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
    _streamSub?.cancel();
    _streamSub = null;

    if (_activeTorrentId != null && lt.LibtorrentFlutter.isInitialized) {
      try {
        lt.LibtorrentFlutter.instance.disposeTorrent(_activeTorrentId!);
      } catch (_) {}
      _activeTorrentId = null;
      _activeStreamId = null;
    }

    _cleanupSaveDir();
    _streamStarted = false;
    _emit(const TorrentState(phase: TorrentPhase.idle));
    debugPrint('[TorrentEngine] Session stopped — temp files deleted');
  }

  /// Stub — kept for API compatibility.
  void onPlaybackProgress(Duration position, Duration duration) {}

  void dispose() {
    stop();
    _stateController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onTorrentUpdate(Map<int, lt.TorrentInfo> torrents) {
    if (_activeTorrentId == null) return;
    final t = torrents[_activeTorrentId];
    if (t == null) return;

    if (t.state == lt.TorrentState.error) {
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: t.errorMsg.isNotEmpty ? t.errorMsg : 'Torrent error',
      ));
      return;
    }

    // Once metadata (the file list) is in, kick off the actual HTTP
    // stream — this is the step the old code skipped entirely.
    if (t.hasMetadata && !_streamStarted) {
      _startStream(t.id);
    }

    if (!_streamStarted) {
      _emit(_current.copyWith(
        phase: TorrentPhase.resolving,
        peers: t.numPeers,
      ));
    }
  }

  void _startStream(int torrentId) {
    _streamStarted = true;
    try {
      final engine = lt.LibtorrentFlutter.instance;
      final info = engine.startStream(
        torrentId,
        fileIndex: -1, // auto-select the largest streamable file
        maxCacheBytes: _kMaxCacheBytes,
      );
      _activeStreamId = info.id;

      // Force head+tail preload immediately. This is what actually gets
      // the container's index (moov atom, for mp4) downloaded early
      // instead of waiting for sequential download to crawl all the
      // way there — the direct fix for the gray-screen bug.
      engine.preloadStream(info.id, preloadBytes: _kPreloadBytes);

      _emit(_current.copyWith(
        phase: TorrentPhase.buffering,
        streamUrl: info.url,
      ));

      debugPrint('[TorrentEngine] Stream started → streamId=${info.id}, url=${info.url}');
    } catch (e) {
      debugPrint('[TorrentEngine] startStream failed: $e');
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start stream: $e',
      ));
    }
  }

  void _onStreamUpdate(Map<int, lt.StreamInfo> streams) {
    if (_activeStreamId == null) return;
    final s = streams[_activeStreamId];
    if (s == null) return;

    if (s.streamState == lt.StreamState.error) {
      _emit(_current.copyWith(phase: TorrentPhase.error, errorMessage: 'Stream error'));
      return;
    }

    TorrentPhase phase;
    switch (s.streamState) {
      case lt.StreamState.idle:
        phase = TorrentPhase.resolving;
        break;
      case lt.StreamState.buffering:
      case lt.StreamState.seeking:
        phase = TorrentPhase.buffering;
        break;
      case lt.StreamState.ready:
        // First tick hitting "ready" → ready (triggers navigation).
        // Every tick after that → streaming.
        phase = (_current.phase == TorrentPhase.ready ||
                _current.phase == TorrentPhase.streaming)
            ? TorrentPhase.streaming
            : TorrentPhase.ready;
        break;
      case lt.StreamState.error:
        phase = TorrentPhase.error;
        break;
    }

    _emit(_current.copyWith(
      phase: phase,
      downloadSpeedMbs: s.downloadRate / (1024 * 1024),
      bufferSeconds: s.bufferSeconds,
      bufferPct: s.bufferPct,
      peers: s.activePeers,
      streamUrl: s.url,
    ));
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
