import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

// ── TorrentEngine ─────────────────────────────────────────────────────────────
//
// Wraps libtorrent_flutter v1.8.2 to provide sequential P2P streaming.
//
// Design:
//   • One active torrent at a time — calling start() cancels any prior session
//   • Downloads into getTemporaryDirectory() — Android auto-clears this,
//     never touches user storage
//   • Uses LibtorrentFlutter.instance (singleton) — never construct directly
//   • Streaming via engine.startStream() which returns a StreamInfo with a URL
//   • Fires TorrentState updates via a Stream for the UI to consume
//
// Usage:
//   final engine = TorrentEngine();
//   engine.stateStream.listen((state) { ... });
//   await engine.start(magnetLink);
//   final url = engine.streamUrl; // pass to PlayerScreen
//   await engine.stop();          // call on dispose

const int _kReadyThresholdMb = 8; // MB buffered before we allow playback

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
  final double downloadSpeedMbs;  // MB/s
  final double progressPercent;   // 0–100, of entire torrent
  final double bufferedMb;        // MB downloaded so far
  final double totalMb;           // total torrent size
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
  // v1.8.2: use the static singleton, never construct LibtorrentFlutter()
  final _engine = LibtorrentFlutter.instance;

  int? _activeTorrentId;
  int? _activeStreamId;
  StreamSubscription<Map<int, TorrentInfo>>? _torrentSub;
  StreamSubscription<Map<int, StreamInfo>>? _streamSub;

  final _stateController = StreamController<TorrentState>.broadcast();
  TorrentState _current = const TorrentState(phase: TorrentPhase.idle);

  // ── Public API ─────────────────────────────────────────────────────────────

  Stream<TorrentState> get stateStream => _stateController.stream;
  TorrentState get currentState => _current;

  /// The localhost stream URL — valid only when phase == ready or streaming.
  String? get streamUrl => _current.streamUrl;

  /// Start a new torrent session from a magnet link.
  /// Cancels any existing session first.
  Future<void> start(String magnetLink) async {
    await stop(); // clean up previous session

    _emit(_current.copyWith(phase: TorrentPhase.resolving));

    try {
      final tempDir = await getTemporaryDirectory();
      final saveDir = Directory('${tempDir.path}/inflex_stream');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);

      // v1.8.2: init once with defaultSavePath (no-op if already initialised)
      await LibtorrentFlutter.init(
        defaultSavePath: saveDir.path,
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 500),
      );

      // v1.8.2: addMagnet() takes just the magnet string, returns int torrent ID
      _activeTorrentId = _engine.addMagnet(magnetLink);

      // Subscribe to live torrent updates from the engine stream
      _torrentSub = _engine.torrentUpdates.listen(_onTorrentUpdate);

      debugPrint('[TorrentEngine] Session started → torrentId=$_activeTorrentId');
    } catch (e) {
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start torrent: $e',
      ));
    }
  }

  /// Stop the current session and clean up temp files.
  Future<void> stop() async {
    _torrentSub?.cancel();
    _torrentSub = null;
    _streamSub?.cancel();
    _streamSub = null;

    // Stop stream if active
    if (_activeStreamId != null) {
      try { _engine.stopStream(_activeStreamId!); } catch (_) {}
      _activeStreamId = null;
    }

    // Remove torrent + delete downloaded files
    if (_activeTorrentId != null) {
      try {
        _engine.removeTorrent(_activeTorrentId!, deleteFiles: true);
      } catch (_) {}
      _activeTorrentId = null;
    }

    _emit(const TorrentState(phase: TorrentPhase.idle));
    debugPrint('[TorrentEngine] Session stopped');
  }

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
      // First time we cross the threshold — kick off the HTTP stream
      phase = TorrentPhase.ready;
      _startStream();
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

  void _startStream() {
    if (_activeTorrentId == null || _activeStreamId != null) return;
    try {
      // v1.8.2: startStream(torrentId) picks the largest streamable file
      // fileIndex: -1 is the default (auto-select)
      final streamInfo = _engine.startStream(_activeTorrentId!);
      _activeStreamId = streamInfo.id;

      // Update state with the stream URL immediately
      _emit(_current.copyWith(streamUrl: streamInfo.url));

      // Watch stream updates for buffering progress
      _streamSub = _engine.streamUpdates.listen((streams) {
        final info = streams[_activeStreamId];
        if (info == null) return;
        if (info.isReady && _current.phase != TorrentPhase.streaming) {
          _emit(_current.copyWith(
            phase: TorrentPhase.streaming,
            streamUrl: info.url,
          ));
        }
      });

      debugPrint('[TorrentEngine] Stream started → ${streamInfo.url}');
    } catch (e) {
      debugPrint('[TorrentEngine] startStream error: $e');
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start HTTP stream: $e',
      ));
    }
  }

  void _emit(TorrentState state) {
    _current = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}
