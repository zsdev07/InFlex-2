import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

// ── TorrentEngine ─────────────────────────────────────────────────────────────
//
// Wraps libtorrent_flutter to provide sequential P2P streaming.
//
// Design:
//   • One active torrent at a time — calling start() cancels any prior session
//   • Downloads into getTemporaryDirectory() — Android auto-clears this,
//     never touches user storage
//   • Sequential mode ON + sliding window: prioritizes the next 200 MB of
//     pieces ahead of the playhead, deprioritizes everything behind
//   • Exposes a localhost HTTP URL for media_kit to point at
//   • Fires TorrentState updates via a Stream for the UI to consume
//
// Usage:
//   final engine = TorrentEngine();
//   engine.stateStream.listen((state) { ... });
//   await engine.start(magnetLink);
//   final url = engine.streamUrl; // pass to PlayerScreen
//   await engine.stop();          // call on dispose

const int _kStreamPort    = 8888;   // localhost HTTP server port
const int _kWindowMb      = 200;    // sliding window size ahead of playhead
const int _kReadyThresholdMb = 8;   // MB buffered before we allow playback

enum TorrentPhase {
  idle,
  resolving,   // fetching metadata from DHT
  buffering,   // downloading initial buffer
  ready,       // enough buffered — player can start
  streaming,   // player is playing, window sliding
  error,
}

class TorrentState {
  final TorrentPhase phase;
  final double downloadSpeedMbs;   // MB/s
  final double progressPercent;    // 0–100, of entire torrent
  final double bufferedMb;         // MB downloaded so far
  final double totalMb;            // total torrent size
  final int peers;
  final String? errorMessage;
  final String? streamUrl;

  const TorrentState({
    required this.phase,
    this.downloadSpeedMbs = 0,
    this.progressPercent = 0,
    this.bufferedMb = 0,
    this.totalMb = 0,
    this.peers = 0,
    this.errorMessage,
    this.streamUrl,
  });

  TorrentState copyWith({
    TorrentPhase? phase,
    double? downloadSpeedMbs,
    double? progressPercent,
    double? bufferedMb,
    double? totalMb,
    int? peers,
    String? errorMessage,
    String? streamUrl,
  }) =>
      TorrentState(
        phase: phase ?? this.phase,
        downloadSpeedMbs: downloadSpeedMbs ?? this.downloadSpeedMbs,
        progressPercent: progressPercent ?? this.progressPercent,
        bufferedMb: bufferedMb ?? this.bufferedMb,
        totalMb: totalMb ?? this.totalMb,
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
  LibtorrentFlutter? _session;
  Timer? _pollTimer;
  final _stateController = StreamController<TorrentState>.broadcast();

  TorrentState _current = const TorrentState(phase: TorrentPhase.idle);

  // ── Public API ─────────────────────────────────────────────────────────────

  Stream<TorrentState> get stateStream => _stateController.stream;
  TorrentState get currentState => _current;

  /// The localhost URL for media_kit to point at.
  /// Valid only when phase == ready or streaming.
  String get streamUrl => 'http://localhost:$_kStreamPort/stream';

  /// Start a new torrent session from a magnet link.
  /// Cancels any existing session first.
  Future<void> start(String magnetLink) async {
    await stop(); // clean up previous session

    _emit(_current.copyWith(phase: TorrentPhase.resolving));

    try {
      final tempDir = await getTemporaryDirectory();
      final saveDir = Directory('${tempDir.path}/inflex_stream');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);

      _session = LibtorrentFlutter();

      await _session!.addMagnet(
        magnetLink,
        savePath: saveDir.path,
        sequentialDownload: true,   // pieces in order — critical for streaming
        streamPort: _kStreamPort,   // start built-in HTTP server
      );

      // Start polling libtorrent for status every 1 second
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());

      debugPrint('[TorrentEngine] Session started → $saveDir');
    } catch (e) {
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start torrent: $e',
      ));
    }
  }

  /// Stop the current session and clean up temp files.
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;

    try {
      await _session?.stop();
    } catch (_) {}
    _session = null;

    // Clean temp download dir
    try {
      final tempDir = await getTemporaryDirectory();
      final saveDir = Directory('${tempDir.path}/inflex_stream');
      if (saveDir.existsSync()) {
        saveDir.deleteSync(recursive: true);
      }
    } catch (_) {}

    _emit(const TorrentState(phase: TorrentPhase.idle));
    debugPrint('[TorrentEngine] Session stopped, temp cleaned');
  }

  /// Call this when the player reports a new playback position.
  /// Slides the download priority window forward.
  void onPlaybackProgress(Duration position, Duration duration) {
    if (_session == null) return;
    if (duration.inSeconds == 0) return;

    // Calculate byte offset of current playhead
    final totalMb = _current.totalMb;
    if (totalMb == 0) return;

    final positionFraction = position.inMilliseconds / duration.inMilliseconds;
    final positionMb = positionFraction * totalMb;

    // Prioritize pieces in the window ahead of playhead
    final windowStartMb = positionMb;
    final windowEndMb   = positionMb + _kWindowMb;

    try {
      _session!.setPiecePriorityRange(
        startMb: windowStartMb,
        endMb: windowEndMb.clamp(0, totalMb),
        priority: 7,     // highest
      );
      // Deprioritize behind playhead (don't cancel — might seek back)
      if (windowStartMb > 50) {
        _session!.setPiecePriorityRange(
          startMb: 0,
          endMb: windowStartMb - 50,
          priority: 1,   // lowest
        );
      }
    } catch (_) {}
  }

  void dispose() {
    stop();
    _stateController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _poll() async {
    if (_session == null) return;

    try {
      final status = await _session!.getStatus();

      final totalMb      = (status.totalBytes ?? 0) / (1024 * 1024);
      final downloadedMb = (status.downloadedBytes ?? 0) / (1024 * 1024);
      final speedMbs     = (status.downloadRate ?? 0) / (1024 * 1024);
      final peers        = status.numPeers ?? 0;
      final progress     = totalMb > 0 ? (downloadedMb / totalMb) * 100 : 0.0;

      TorrentPhase phase;

      if (_current.phase == TorrentPhase.resolving && peers == 0) {
        phase = TorrentPhase.resolving;
      } else if (downloadedMb < _kReadyThresholdMb) {
        phase = TorrentPhase.buffering;
      } else if (_current.phase == TorrentPhase.buffering ||
                 _current.phase == TorrentPhase.resolving) {
        // First time we cross the threshold — signal ready
        phase = TorrentPhase.ready;
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
        streamUrl: streamUrl,
      ));
    } catch (e) {
      debugPrint('[TorrentEngine] Poll error: $e');
    }
  }

  void _emit(TorrentState state) {
    _current = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}
