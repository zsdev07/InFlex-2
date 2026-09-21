import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:intorrent/intorrent.dart' as intorrent;

// ── TorrentEngine ─────────────────────────────────────────────────────────────
//
// Wraps InTorrent to provide P2P playback.
//
// ── WHY THIS FILE WAS REWRITTEN (again) ─────────────────────────────────────
// Previously wrapped libtorrent_flutter, a third-party plugin whose
// startStream()/preloadStream() APIs were fine once tuned correctly, but
// whose underlying networking had unresolved issues on real devices. This
// now wraps InTorrent (our own plugin, github.com/zsdev07/InTorrent),
// built and hardened specifically against the failure modes hit in
// production: a libtorrent internal-assert crash, a silently-broken
// Android network stack (libtorrent's optional enable_ip_notifier feature
// throwing on Android's SELinux-restricted netlink and taking the whole
// session down with it — completely unrelated to the actual listen
// socket), and a save_path placeholder that resolved to an unwritable
// directory. All three fixed at the native layer; see InTorrent's own
// history for the full diagnostic trail.
//
// ── API SHAPE DELIBERATELY UNCHANGED ────────────────────────────────────────
// TorrentPhase, TorrentState, and TorrentEngine's public surface
// (stateStream, currentState, streamUrl, start(), stop(), dispose(),
// onPlaybackProgress() stub) are all unchanged from the libtorrent_flutter
// version - torrent_loading_screen.dart and torrent_player_screen.dart
// need no changes at all. Only this file's internals changed.
//
// ── KEY DIFFERENCES FROM libtorrent_flutter, HANDLED BELOW ──────────────────
//   • No event streams - InTorrent only exposes synchronous getStatus()
//     polling. Replaced torrentUpdates/streamUpdates subscriptions with a
//     Timer.periodic poll loop (_poll()).
//   • No "auto-pick the largest file" - InTorrent's streamUrl() needs an
//     explicit file index. Added _pickVideoFile(), using listFiles() once
//     metadata arrives: prefers the largest file with a known video
//     extension, falls back to the largest file overall if none match
//     (torrents often bundle subs/NFO/poster alongside the video - see
//     InTorrent's listFiles() doc comment).
//   • Pre-buffer gate: we used to flip to `ready` the moment streamUrl()
//     returned a URL, so the player opened with ZERO bytes buffered and
//     spent its first minute rebuffering. Now `ready` waits until the head
//     of the file is contiguously downloaded (see _poll / _preBufferTarget),
//     capped by _maxPreBufferWait so a weak swarm never blocks playback
//     forever. bufferPct during that phase is the real pre-buffer fill.
//   • Smart pre-buffer (Settings > Experimental, default OFF): no timer -
//     waits for a ~1% head buffer and only stops waiting when the head has
//     not grown for 20 s (state.stalled), then the user chooses.
//   • Which file to play: _pickVideoFile() now uses Torrentio's file name /
//     index and the wanted season+episode (StreamFileHint), so season packs
//     no longer play whichever episode is the biggest file.
//   • Pause-prefetch: when the player has been paused for 8 s the engine
//     asks InTorrent to download the next 30 minutes of the movie in strict
//     order at full speed; pressing play cancels it and everything already
//     downloaded is kept. See onPlayingChanged() / _startPrefetch().
//   • No instantaneous download-rate field - only cumulative
//     downloadedBytes. Speed is computed here from the delta between
//     polls.
//   • No save-path management needed here at all - InTorrent handles its
//     own temp directory (and cleans it up on remove()) internally. The
//     old _saveDir/_cleanupSaveDir/path_provider dependency is gone.
//   • No external tracker-list fetching (TrackerManager.fetchBestTrackers())
//     - InTorrent's DHT alone has tested reliably (real peers/seeds within
//     seconds on a plain magnet + one tracker) once its Android networking
//     bugs were fixed, so this wasn't reintroduced. Worth revisiting only
//     if peer discovery turns out to be too slow in practice.
//
// Usage (unchanged):
//   final engine = TorrentEngine();
//   engine.stateStream.listen((state) { ... });
//   await engine.start(magnetLink);
//   final url = engine.streamUrl; // pass straight to Media(url) — it's HTTP
//   await engine.stop();          // call on dispose — deletes temp files

/// Which file inside the torrent to stream. Torrentio tells us the video's
/// index and (for packs) its file name; for series we also know the wanted
/// season/episode. Without this the engine could only pick "the largest
/// video", i.e. the WRONG episode of a season pack.
class StreamFileHint {
  final int? fileIdx;
  final String? fileName;
  final int? season;
  final int? episode;

  const StreamFileHint({this.fileIdx, this.fileName, this.season, this.episode});
}

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

  /// Buffer fill, 0.0–1.0. While phase == buffering this is the real
  /// pre-buffer fill (contiguous head bytes / target). Afterwards it's
  /// InTorrent's overall download progress.
  final double bufferPct;
  final int peers;
  final String? errorMessage;

  /// HTTP stream URL — valid when phase == ready or streaming.
  /// Open directly with: Media(streamUrl) — no file:// wrapping needed.
  final String? streamUrl;

  // ── Raw diagnostics — surfaced directly from InTorrent's own
  // TorrentStatus, unfiltered, for debugging the plugin itself rather
  // than our simplified phase/peers summary above.
  final String nativeState; // InTorrent's TorrentState.name, not ours
  final int numSeeds;
  final bool isPaused;

  /// No InTorrent equivalent (libtorrent doesn't expose a torrent
  /// queue position the way the old plugin's wrapper did) - always -1.
  /// The debug panel already hides this when < 0.
  final int queuePosition;

  /// No InTorrent equivalent for a version string - left as a fixed
  /// label so the debug panel shows which engine is active rather than
  /// falling back to its "—" empty-state.
  final String libraryVersion;

  /// True while a pause-prefetch is running, and how much of its window
  /// (0.0-1.0) is already downloaded.
  final bool prefetching;
  final double prefetchPct;

  /// Smart pre-buffer only: the start of the movie has stopped growing for a
  /// while (dead/slow source). The loading screen then offers to keep
  /// waiting, play anyway, or pick another source.
  final bool stalled;

  const TorrentState({
    required this.phase,
    this.downloadSpeedMbs = 0,
    this.bufferSeconds = 0,
    this.bufferPct = 0,
    this.peers = 0,
    this.errorMessage,
    this.streamUrl,
    this.nativeState = '',
    this.numSeeds = 0,
    this.isPaused = false,
    this.queuePosition = -1,
    this.libraryVersion = '',
    this.prefetching = false,
    this.prefetchPct = 0,
    this.stalled = false,
  });

  TorrentState copyWith({
    TorrentPhase? phase,
    double? downloadSpeedMbs,
    double? bufferSeconds,
    double? bufferPct,
    int? peers,
    String? errorMessage,
    String? streamUrl,
    String? nativeState,
    int? numSeeds,
    bool? isPaused,
    int? queuePosition,
    String? libraryVersion,
    bool? prefetching,
    double? prefetchPct,
    bool? stalled,
  }) =>
      TorrentState(
        phase: phase ?? this.phase,
        downloadSpeedMbs: downloadSpeedMbs ?? this.downloadSpeedMbs,
        bufferSeconds: bufferSeconds ?? this.bufferSeconds,
        bufferPct: bufferPct ?? this.bufferPct,
        peers: peers ?? this.peers,
        errorMessage: errorMessage ?? this.errorMessage,
        streamUrl: streamUrl ?? this.streamUrl,
        nativeState: nativeState ?? this.nativeState,
        numSeeds: numSeeds ?? this.numSeeds,
        isPaused: isPaused ?? this.isPaused,
        queuePosition: queuePosition ?? this.queuePosition,
        libraryVersion: libraryVersion ?? this.libraryVersion,
        prefetching: prefetching ?? this.prefetching,
        prefetchPct: prefetchPct ?? this.prefetchPct,
        stalled: stalled ?? this.stalled,
      );

  String get displayMessage {
    switch (phase) {
      case TorrentPhase.idle:
        return 'Idle';
      case TorrentPhase.resolving:
        return 'Connecting to peers via DHT...';
      case TorrentPhase.buffering:
        if (stalled) {
          return 'This source has stopped loading • $peers peers';
        }
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

/// Video extensions checked (in order of preference over any other file
/// type) when picking which file inside a multi-file torrent to stream -
/// see _pickVideoFile().
const _videoExtensions = {
  '.mp4', '.mkv', '.avi', '.mov', '.webm', '.m4v', '.ts', '.wmv', '.flv', '.m2ts',
};

class TorrentEngine {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final TorrentEngine _instance = TorrentEngine._internal();
  factory TorrentEngine() => _instance;
  TorrentEngine._internal();

  // ── Internal state ─────────────────────────────────────────────────────────
  int? _activeId;
  bool _streamStarted = false;

  Timer? _pollTimer;
  Timer? _metadataTimer;

  int? _lastDownloadedBytes;
  DateTime? _lastPollTime;

  // Which file is being streamed (set in _startStream).
  int _fileIndex = -1;
  int _fileSize = 0;
  String? _fileName;

  /// Name / size of the file being streamed (null / 0 until it is picked).
  /// Used to ask the subtitle service for subtitles that match this release.
  String? get streamFileName => _fileName;
  int get streamFileSize => _fileSize;

  // ── Pre-buffer gate ────────────────────────────────────────────────────────
  // Don't hand the stream to the player until this many bytes at the start
  // of the file are downloaded contiguously. ~0.5% of the file, clamped to
  // 8-32 MiB (≈ 19 MB for a 3.8 GB movie).
  static const int _minPreBufferBytes = 8 * 1024 * 1024;
  static const int _maxPreBufferBytes = 32 * 1024 * 1024;
  // Never wait longer than this - a weak swarm must not block playback.
  static const Duration _maxPreBufferWait = Duration(seconds: 25);
  bool _gatePassed = false;
  int _preBufferTarget = 0;
  DateTime? _streamStartedAt;

  // ── Smart pre-buffer (experimental setting, default OFF) ───────────────────
  // ON: no fixed timer. Wait for a bigger head buffer (~1% of the file,
  // 16-64 MiB) and only escape when the head STOPS GROWING for _stallAfter -
  // then the user decides (keep waiting / play anyway / other source).
  static const int _smartMinPreBufferBytes = 16 * 1024 * 1024;
  static const int _smartMaxPreBufferBytes = 64 * 1024 * 1024;
  static const Duration _stallAfter = Duration(seconds: 20);
  bool _smartPreBuffer = false;
  bool _forcePlay = false;
  int _lastHead = 0;
  DateTime _lastHeadAt = DateTime.now();

  StreamFileHint? _fileHint;

  // ── Pause-prefetch ─────────────────────────────────────────────────────────
  /// Player must stay paused this long before the prefetch kicks in.
  static const Duration _pauseBeforePrefetch = Duration(seconds: 8);

  /// How much movie (not wall-clock) the prefetch aims to have ready.
  static const Duration _prefetchSpan = Duration(minutes: 30);

  /// Lower bound for the prefetch window, whatever the bitrate estimate says.
  static const int _minPrefetchBytes = 32 * 1024 * 1024;

  Timer? _prefetchTimer;
  bool _playing = false;
  bool _everPlayed = false; // ignore the initial "paused before first play"
  Duration _playerDuration = Duration.zero;
  bool _prefetching = false;
  int _prefetchStart = 0;
  int _prefetchLength = 0;
  bool _prefetchDoneLogged = false;

  final _stateController = StreamController<TorrentState>.broadcast();
  TorrentState _current = const TorrentState(phase: TorrentPhase.idle);

  // ── Public API ─────────────────────────────────────────────────────────────

  Stream<TorrentState> get stateStream => _stateController.stream;
  TorrentState get currentState => _current;

  /// HTTP stream URL — valid when phase == ready or streaming.
  String? get streamUrl => _current.streamUrl;

  /// Start a new torrent session. Cancels any prior session first.
  Future<void> start(
    String magnetLink, {
    StreamFileHint? fileHint,
    bool smartPreBuffer = false,
  }) async {
    await stop();
    _fileHint = fileHint;
    _smartPreBuffer = smartPreBuffer;
    _forcePlay = false;
    _lastHead = 0;
    _lastHeadAt = DateTime.now();
    _emit(const TorrentState(
      phase: TorrentPhase.resolving,
      libraryVersion: 'InTorrent (libtorrent 2.1.1)',
    ));

    try {
      final id = await intorrent.addMagnet(magnetLink);
      _activeId = id;
      _streamStarted = false;
      _lastDownloadedBytes = null;
      _lastPollTime = null;
      debugPrint('[TorrentEngine] addMagnet returned id=$id');

      // Same 45s "no peers ever showed up" surfacing as before - a
      // torrent with dead/unreachable trackers and no DHT bootstrap
      // gets a clear error instead of an infinite "resolving" spinner.
      _metadataTimer = Timer(const Duration(seconds: 45), () {
        if (!_streamStarted) {
          _emit(_current.copyWith(
            phase: TorrentPhase.error,
            errorMessage:
                'No peers found after 45s. Your network may be blocking '
                'torrent traffic (common on mobile data / restrictive Wi-Fi).',
          ));
        }
      });

      _pollTimer =
          Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());

      debugPrint('[TorrentEngine] Session started → torrentId=$id');
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
    _pollTimer?.cancel();
    _pollTimer = null;
    _metadataTimer?.cancel();
    _metadataTimer = null;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _prefetching = false;
    _prefetchDoneLogged = false;
    _playing = false;
    _everPlayed = false;
    _gatePassed = false;
    _forcePlay = false;
    _fileHint = null;
    _fileIndex = -1;
    _fileSize = 0;
    _fileName = null;

    final id = _activeId;
    if (id != null) {
      // remove() deletes InTorrent's own temp files for this torrent
      // internally - no separate save-dir cleanup needed here (see
      // file header).
      try {
        await intorrent.remove(id);
      } catch (_) {}
      _activeId = null;
      _streamStarted = false;
    }

    _emit(const TorrentState(phase: TorrentPhase.idle));
    debugPrint('[TorrentEngine] Session stopped — temp files deleted');
  }

  /// Stub — kept for API compatibility.
  void onPlaybackProgress(Duration position, Duration duration) {}

  /// For the player's seek bar: how far (0.0-1.0, counted in bytes, so it is
  /// an approximation for variable-bitrate files) the file is downloaded
  /// CONTIGUOUSLY from the byte where [position] roughly lies. Never less
  /// than the playhead itself; 0 if nothing is known yet.
  Future<double> downloadedUpTo(Duration position, Duration duration) async {
    final id = _activeId;
    if (id == null ||
        !_streamStarted ||
        _fileIndex < 0 ||
        _fileSize <= 0 ||
        duration.inMilliseconds <= 0) {
      return 0.0;
    }
    final startByte =
        ((position.inMilliseconds / duration.inMilliseconds) * _fileSize)
            .floor()
            .clamp(0, _fileSize - 1)
            .toInt();
    try {
      final got = await intorrent.availableBytes(
          id, _fileIndex, startByte, _fileSize - startByte);
      return ((startByte + got) / _fileSize).clamp(0.0, 1.0).toDouble();
    } catch (_) {
      return 0.0;
    }
  }

  // ── Pause-prefetch API (called from torrent_player_screen.dart) ────────────

  /// Tell the engine whether the player is currently playing.
  ///
  /// * playing == false: after [_pauseBeforePrefetch] of continuous pause the
  ///   engine starts prefetching the next [_prefetchSpan] of the movie.
  /// * playing == true: any running prefetch is cancelled and the whole file
  ///   goes back to normal in-order streaming. Whatever the prefetch had
  ///   already downloaded is kept - it's the same file the player reads.
  ///
  /// [duration] is the player's current media duration (used to convert
  /// "30 minutes" into bytes); Duration.zero if not known yet.
  void onPlayingChanged({required bool playing, required Duration duration}) {
    _playing = playing;
    if (duration > Duration.zero) _playerDuration = duration;

    _prefetchTimer?.cancel();
    _prefetchTimer = null;

    if (playing) {
      _everPlayed = true;
      unawaited(_cancelPrefetch());
      return;
    }
    _armPrefetchTimer();
  }

  /// Call when the user seeks. If the player is paused, a running prefetch
  /// (which was anchored at the old position) is cancelled and re-armed so it
  /// restarts from the new position after another [_pauseBeforePrefetch].
  void onUserSeek({required Duration duration}) {
    if (duration > Duration.zero) _playerDuration = duration;
    if (_playing) return;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    unawaited(_cancelPrefetch());
    _armPrefetchTimer();
  }

  void _armPrefetchTimer() {
    if (!_streamStarted || !_everPlayed || _playing) return;
    _prefetchTimer = Timer(_pauseBeforePrefetch, _startPrefetch);
  }

  Future<void> _startPrefetch() async {
    _prefetchTimer = null;
    final id = _activeId;
    if (id == null ||
        !_streamStarted ||
        _playing ||
        _prefetching ||
        _fileIndex < 0 ||
        _fileSize <= 0) {
      return;
    }

    // "30 minutes of movie" -> bytes, from the real bitrate of THIS file
    // (file size / media duration). Falls back to a 2 h runtime if the
    // player hasn't reported a duration.
    final seconds = _playerDuration.inMilliseconds > 0
        ? _playerDuration.inMilliseconds / 1000.0
        : 2 * 3600.0;
    final bytesPerSecond = _fileSize / seconds;
    // (min() so tiny files can't make clamp() see lower > upper and throw)
    final minBytes =
        _fileSize < _minPrefetchBytes ? _fileSize : _minPrefetchBytes;
    final length = (bytesPerSecond * _prefetchSpan.inSeconds)
        .round()
        .clamp(minBytes, _fileSize)
        .toInt();

    // Start where the player will read NEXT (it may already hold tens of MB
    // beyond the playhead in its own cache), not at the playhead itself.
    final start = intorrent.streamReadCursor(id) ?? 0;
    if (start >= _fileSize) return;

    try {
      await intorrent.startPrefetch(id, _fileIndex,
          startByte: start, lengthBytes: length);
    } catch (e) {
      debugPrint('[TorrentEngine] prefetch start failed: $e');
      return;
    }

    _prefetching = true;
    _prefetchStart = start;
    _prefetchLength = length;
    _prefetchDoneLogged = false;
    debugPrint('[TorrentEngine] prefetch started: from byte $start, '
        '${(length / (1024 * 1024)).toStringAsFixed(0)} MiB');

    // The user may have pressed play (or left) while the native call ran.
    if (_playing || _activeId != id) {
      await _cancelPrefetch();
      return;
    }
    _emit(_current.copyWith(prefetching: true, prefetchPct: 0));
  }

  Future<void> _cancelPrefetch() async {
    if (!_prefetching) return;
    _prefetching = false;
    final id = _activeId;
    if (id != null) {
      try {
        await intorrent.cancelPrefetch(id);
      } catch (_) {}
    }
    debugPrint('[TorrentEngine] prefetch cancelled (downloaded data kept)');
    _emit(_current.copyWith(prefetching: false, prefetchPct: 0));
  }

  void dispose() {
    stop();
    _stateController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _poll() async {
    final id = _activeId;
    if (id == null) return;

    intorrent.TorrentStatus status;
    try {
      status = await intorrent.getStatus(id);
    } catch (e) {
      // Torrent id not found (e.g. removed mid-poll) or a transient FFI
      // hiccup - skip this tick rather than tearing down the session
      // over one failed poll.
      debugPrint('[TorrentEngine] getStatus failed: $e');
      return;
    }

    // InTorrent's status snapshot has no rate field, only cumulative
    // downloaded bytes - derive a rough instantaneous speed from the
    // delta between polls.
    double speedMbs = 0;
    final now = DateTime.now();
    if (_lastDownloadedBytes != null && _lastPollTime != null) {
      final deltaBytes = status.downloadedBytes - _lastDownloadedBytes!;
      final deltaSeconds =
          now.difference(_lastPollTime!).inMilliseconds / 1000.0;
      if (deltaSeconds > 0 && deltaBytes > 0) {
        speedMbs = (deltaBytes / deltaSeconds) / (1024 * 1024);
      }
    }
    _lastDownloadedBytes = status.downloadedBytes;
    _lastPollTime = now;

    // Once real metadata is in (state has moved past
    // downloadingMetadata/queued/checking), kick off streaming - guarded
    // so this only ever runs once per session.
    final metadataReady = status.state != intorrent.TorrentState.queued &&
        status.state != intorrent.TorrentState.checking &&
        status.state != intorrent.TorrentState.downloadingMetadata;

    if (!_streamStarted && metadataReady) {
      _metadataTimer?.cancel();
      await _startStream(id);
    }

    if (!_streamStarted) {
      _emit(_current.copyWith(
        phase: TorrentPhase.resolving,
        peers: status.numPeers,
        numSeeds: status.numSeeds,
        nativeState: status.state.name,
        isPaused: status.isPaused,
      ));
      return;
    }

    // Session was stopped/replaced while we were awaiting above.
    if (_activeId != id) return;

    // ── Pre-buffer gate ────────────────────────────────────────────────────
    // Stay in `buffering` (the loading screen keeps showing peers/speed and
    // a real progress bar) until the head of the file is contiguously
    // downloaded - or _maxPreBufferWait has passed.
    if (!_gatePassed) {
      var head = 0;
      try {
        head = await intorrent.availableBytes(
            id, _fileIndex, 0, _preBufferTarget);
      } catch (_) {}
      if (_activeId != id) return;

      final nowT = DateTime.now();
      final waited = nowT.difference(_streamStartedAt ?? nowT);
      if (head > _lastHead) {
        _lastHead = head;
        _lastHeadAt = nowT;
      }

      final bool pass;
      var stalled = false;
      if (_smartPreBuffer) {
        // No timer: wait for the full target while bytes keep arriving.
        pass = _forcePlay || head >= _preBufferTarget;
        stalled = !pass && nowT.difference(_lastHeadAt) > _stallAfter;
      } else {
        // Default: full target, or give up after _maxPreBufferWait.
        pass = _forcePlay ||
            head >= _preBufferTarget ||
            waited > _maxPreBufferWait;
      }

      if (pass) {
        _gatePassed = true;
        debugPrint('[TorrentEngine] pre-buffer done: '
            '${(head / (1024 * 1024)).toStringAsFixed(1)} MiB '
            'after ${waited.inSeconds}s'
            '${_smartPreBuffer ? " (smart)" : ""}'
            '${_forcePlay ? " (forced)" : ""}');
      } else {
        _emit(_current.copyWith(
          phase: TorrentPhase.buffering,
          downloadSpeedMbs: speedMbs,
          bufferPct: _preBufferTarget > 0
              ? (head / _preBufferTarget).clamp(0.0, 1.0).toDouble()
              : 0.0,
          peers: status.numPeers,
          numSeeds: status.numSeeds,
          nativeState: status.state.name,
          isPaused: status.isPaused,
          stalled: stalled,
        ));
        return;
      }
    }

    // ── Pause-prefetch progress (for the HUD) ────────────────────────────────
    var prefetchPct = 0.0;
    if (_prefetching && _prefetchLength > 0) {
      try {
        final got = await intorrent.availableBytes(
            id, _fileIndex, _prefetchStart, _prefetchLength);
        prefetchPct = (got / _prefetchLength).clamp(0.0, 1.0).toDouble();
        if (prefetchPct >= 1.0 && !_prefetchDoneLogged) {
          _prefetchDoneLogged = true;
          debugPrint('[TorrentEngine] prefetch window complete');
        }
      } catch (_) {}
      if (_activeId != id) return;
    }

    // Streaming path. First tick after the gate passes → ready (triggers
    // navigation in torrent_loading_screen.dart). Every tick after that →
    // streaming.
    final phase = (_current.phase == TorrentPhase.ready ||
            _current.phase == TorrentPhase.streaming)
        ? TorrentPhase.streaming
        : TorrentPhase.ready;

    _emit(_current.copyWith(
      phase: phase,
      downloadSpeedMbs: speedMbs,
      bufferPct: status.progress,
      peers: status.numPeers,
      numSeeds: status.numSeeds,
      nativeState: status.state.name,
      isPaused: status.isPaused,
      prefetching: _prefetching,
      prefetchPct: prefetchPct,
      stalled: false,
    ));
  }

  /// Smart pre-buffer: the user chose to keep waiting after a stall.
  void keepWaiting() {
    _lastHeadAt = DateTime.now();
    _emit(_current.copyWith(stalled: false));
  }

  /// Smart pre-buffer: start playing with whatever is buffered.
  void playAnyway() {
    _forcePlay = true;
    _emit(_current.copyWith(stalled: false));
  }

  Future<void> _startStream(int id) async {
    try {
      final files = await intorrent.listFiles(id);
      final fileIndex = _pickVideoFile(files, _fileHint);
      debugPrint('[TorrentEngine] picked file index=$fileIndex '
          'from ${files.length} file(s): '
          '${files.map((f) => f.name).join(", ")}');

      final url = await intorrent.streamUrl(id, fileIndex);

      _fileIndex = fileIndex;
      _fileSize = 0;
      _fileName = null;
      for (final f in files) {
        if (f.index == fileIndex) {
          _fileSize = f.size;
          _fileName = f.name;
        }
      }
      _preBufferTarget = _smartPreBuffer
          ? (_fileSize ~/ 100)
              .clamp(_smartMinPreBufferBytes, _smartMaxPreBufferBytes)
              .toInt()
          : (_fileSize ~/ 200)
              .clamp(_minPreBufferBytes, _maxPreBufferBytes)
              .toInt();
      if (_fileSize > 0 && _preBufferTarget > _fileSize) {
        _preBufferTarget = _fileSize;
      }
      _gatePassed = false;
      _lastHead = 0;
      _lastHeadAt = DateTime.now();
      _streamStartedAt = DateTime.now();
      _streamStarted = true;

      _emit(_current.copyWith(
        phase: TorrentPhase.buffering,
        streamUrl: url.toString(),
      ));

      debugPrint('[TorrentEngine] Stream started → url=$url');
    } catch (e) {
      debugPrint('[TorrentEngine] startStream failed: $e');
      _emit(_current.copyWith(
        phase: TorrentPhase.error,
        errorMessage: 'Failed to start stream: $e',
      ));
    }
  }

  /// Picks which file inside a (possibly multi-file) torrent to stream.
  ///
  /// Order of trust:
  ///   1. the exact file name Torrentio gave us (packs / collections)
  ///   2. for series: the file whose name carries the wanted SxxEyy
  ///   3. Torrentio's fileIdx, if it points at a real video that isn't
  ///      obviously a different episode or a tiny sample
  ///   4. the largest video (single-movie torrents), else the largest file
  ///
  /// The old version only did (4), so a season pack always played whichever
  /// episode happened to be the biggest file.
  int _pickVideoFile(List<intorrent.TorrentFile> files, StreamFileHint? hint) {
    final videos = files.where(_isVideoFile).toList();
    if (videos.isEmpty) {
      intorrent.TorrentFile? largest;
      for (final f in files) {
        if (largest == null || f.size > largest.size) largest = f;
      }
      return largest?.index ?? 0;
    }

    intorrent.TorrentFile largestVideo = videos.first;
    for (final f in videos) {
      if (f.size > largestVideo.size) largestVideo = f;
    }

    // 1. exact file name
    final wantedName = _baseName(hint?.fileName);
    if (wantedName != null) {
      for (final f in videos) {
        if (_baseName(f.name) == wantedName) return f.index;
      }
    }

    // 2. season/episode in the file name
    final season = hint?.season;
    final episode = hint?.episode;
    if (season != null && episode != null) {
      final matches =
          videos.where((f) => _nameHasEpisode(f.name, season, episode)).toList();
      if (matches.length == 1) return matches.first.index;
      if (matches.length > 1) {
        for (final f in matches) {
          if (f.index == hint?.fileIdx) return f.index;
        }
        matches.sort((x, y) => y.size.compareTo(x.size));
        return matches.first.index;
      }
    }

    // 3. Torrentio's index
    final idx = hint?.fileIdx;
    if (idx != null) {
      for (final f in videos) {
        if (f.index != idx) continue;
        final tiny = f.size < largestVideo.size ~/ 10;
        final otherEpisode = season != null &&
            episode != null &&
            _nameHasOtherEpisode(f.name, season, episode);
        if (!tiny && !otherEpisode) return f.index;
      }
    }

    // 4. largest video
    return largestVideo.index;
  }

  bool _isVideoFile(intorrent.TorrentFile f) {
    final dot = f.name.lastIndexOf('.');
    final ext = dot >= 0 ? f.name.substring(dot).toLowerCase() : '';
    return _videoExtensions.contains(ext);
  }

  /// Lower-cased file name without any folder part (or null if empty).
  String? _baseName(String? path) {
    if (path == null) return null;
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    final name = (cut >= 0 ? path.substring(cut + 1) : path).trim().toLowerCase();
    return name.isEmpty ? null : name;
  }

  bool _nameHasEpisode(String name, int season, int episode) {
    final n = name.toLowerCase();
    return RegExp('s0*$season[\\s._-]*e0*$episode(?!\\d)').hasMatch(n) ||
        RegExp('(?:^|[^0-9])0*${season}x0*$episode(?!\\d)').hasMatch(n) ||
        RegExp('season[\\s._-]*0*$season.*episode[\\s._-]*0*$episode(?!\\d)')
            .hasMatch(n);
  }

  /// True if the name clearly names a DIFFERENT episode than the wanted one.
  bool _nameHasOtherEpisode(String name, int season, int episode) {
    final m = RegExp(r's(\d{1,2})[\s._-]*e(\d{1,3})').firstMatch(name.toLowerCase());
    if (m == null) return false;
    final s = int.tryParse(m.group(1)!);
    final e = int.tryParse(m.group(2)!);
    return s != season || e != episode;
  }

  void _emit(TorrentState state) {
    _current = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }
}
