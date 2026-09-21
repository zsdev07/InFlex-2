import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/subtitle_service.dart';
import '../services/torrent_engine.dart';

// ── TorrentPlayerScreen ───────────────────────────────────────────────────────
//
// Screen 2 of 2 in the P2P flow. Receives the localhost stream URL from
// TorrentLoadingScreen once the engine signals TorrentPhase.ready.
//
// Rebuilt with a YouTube-style layout and behaviour:
//
//   • One control layer. The old screen drew its own overlay ON TOP OF
//     media_kit's built-in controls (Video() defaults to
//     AdaptiveVideoControls), so two control systems fought over every tap.
//     Video now uses NoVideoControls and everything is ours.
//   • Single tap shows/hides the controls. Double-tap left/right seeks
//     ±10 s (taps in quick succession keep adding: 20 s, 30 s ...).
//     Double-tap centre = play/pause. Long-press = 2x while held.
//     Vertical swipe on the right half = volume.
//   • Controls STAY visible while paused, buffering, scrubbing, or while a
//     menu is open. They only auto-hide (after 3.5 s) during playback.
//   • Seek bar: drag shows a time bubble and seeks ONCE on release (the old
//     slider seeked on every drag tick, i.e. hundreds of range requests
//     against the torrent). A lighter segment shows how much of the movie
//     is really downloaded ahead of the playhead.
//   • Buffering spinner with live peers / speed instead of a frozen frame.
//   • Subtitles: embedded tracks (any language) + size / background
//     options, rendered by us so they lift above the controls like YouTube.
//     Audio-track picker (Hindi / English dubs).
//   • Only small widgets listen to the (throttled) position, so the screen
//     no longer rebuilds dozens of times per second.
//   • Still reports play/pause + seeks to the engine (drives the 8 s pause
//     -> 30 min prefetch) and stops the engine on dispose.

/// Accent colour of the seek bar, spinner and highlights. Change here to
/// re-theme (e.g. Color(0xFFFF0033) for the YouTube red).
const Color _accent = Color(0xFFFFCC00);
const Color _sheetBg = Color(0xFF17171F);
const Duration _hideAfter = Duration(milliseconds: 3500);

class TorrentPlayerScreen extends StatefulWidget {
  final String streamUrl;
  final String title;
  final String quality;
  final TorrentEngine engine;

  /// Lets the player look up English subtitles online (null = no lookup).
  final SubtitleQuery? subtitleQuery;

  const TorrentPlayerScreen({
    super.key,
    required this.streamUrl,
    required this.title,
    required this.quality,
    required this.engine,
    this.subtitleQuery,
  });

  @override
  State<TorrentPlayerScreen> createState() => _TorrentPlayerScreenState();
}

class _TorrentPlayerScreenState extends State<TorrentPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  final List<StreamSubscription<dynamic>> _subs = [];

  // Small notifiers so only the widgets that need them rebuild.
  final ValueNotifier<Duration> _position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<double> _downloadedUpTo = ValueNotifier<double>(0.0);
  final ValueNotifier<double?> _dragValue = ValueNotifier<double?>(null);
  final ValueNotifier<TorrentState> _engineState = ValueNotifier<TorrentState>(
      const TorrentState(phase: TorrentPhase.streaming));
  final ValueNotifier<_HudInfo?> _hud = ValueNotifier<_HudInfo?>(null);

  // Online (English) subtitles - see _loadOnlineSubtitles().
  final ValueNotifier<_OnlineSubs> _online =
      ValueNotifier<_OnlineSubs>(const _OnlineSubs(_OnlineStatus.idle));
  int? _activeOnline; // which online option is loaded (null = none)
  double _subDelay = 0.0; // seconds; positive = subtitles appear later

  // Player state that changes rarely -> plain setState is fine.
  bool _playing = false;
  bool _buffering = false;
  // True from the moment the screen opens until mpv reports a duration or
  // starts playing. mpv only emits `buffering` on CHANGES, so relying on
  // it alone would show no spinner while the stream is first opening.
  bool _opening = true;
  bool _completed = false;
  bool _controlsVisible = true;
  bool _locked = false;
  bool _unlockHint = false;
  bool _scrubbing = false;
  int _menusOpen = 0;
  double _rate = 1.0;
  String? _error;

  // Subtitle look (kept for the app session).
  static double _subScale = 1.0;
  static bool _subBackground = true;

  // Gesture bookkeeping.
  double _lastTapX = 0;
  int _rippleSide = 0; // -1 left, 0 none, 1 right
  int _chainSeconds = 0;
  bool _dragOnRight = false;
  double _volAtDragStart = 100;
  double _volDragAccum = 0;
  double _rateBeforeHold = 1.0;

  Timer? _hideTimer;
  Timer? _posTimer;
  Timer? _dlTimer;
  Timer? _hudTimer;
  Timer? _chainTimer;
  Timer? _unlockTimer;
  Duration _lastPos = Duration.zero;

  bool get _menuOpen => _menusOpen > 0;
  bool get _busy => _buffering || _opening;

  /// Controls are forced visible whenever the user could need them.
  bool get _controlsShown =>
      !_locked &&
      (_controlsVisible ||
          !_playing ||
          _busy ||
          _completed ||
          _menuOpen ||
          _scrubbing);

  @override
  void initState() {
    super.initState();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _player = Player(
      configuration: const PlayerConfiguration(
        // Warnings/errors only: every debug line used to cross native ->
        // Dart and get print()-ed on the UI isolate.
        logLevel: MPVLogLevel.warn,
        // mpv demuxer read-ahead; the played-data back-buffer is trimmed
        // again in _initAndOpen().
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      // `hevc_mediacodec: Both surface and native_window are NULL` (seen in
      // the logs) = zero-copy MediaCodec failing and mpv falling back to
      // software decoding. mediacodec-copy needs no surface. Remove this
      // argument if a specific device regresses.
      configuration: const VideoControllerConfiguration(
        hwdec: 'mediacodec-copy',
      ),
    );

    _subs.add(_player.stream.error.listen((err) {
      // ignore: avoid_print
      print('[TorrentPlayerScreen] player error: $err');
      if (mounted) setState(() => _error = err);
    }));

    // Tell the engine when playback pauses/resumes: after 8 s paused it
    // prefetches the next 30 minutes in order (TorrentEngine.onPlayingChanged).
    _subs.add(_player.stream.playing.listen((playing) {
      widget.engine.onPlayingChanged(
        playing: playing,
        duration: _player.state.duration,
      );
      if (!mounted) return;
      setState(() {
        _playing = playing;
        // Show the controls for a moment when playback (re)starts, so
        // pressing play never makes them vanish instantly.
        if (playing) {
          _controlsVisible = true;
          _opening = false;
        }
      });
      _scheduleHide();
    }));

    _subs.add(_player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _buffering = buffering);
      _scheduleHide();
    }));

    _subs.add(_player.stream.completed.listen((completed) {
      if (!mounted) return;
      setState(() => _completed = completed);
    }));

    _subs.add(_player.stream.duration.listen((d) {
      _duration.value = d;
      if (d > Duration.zero && _opening && mounted) {
        setState(() => _opening = false);
      }
    }));

    // mpv can report time-pos once per video frame. Re-emit at most 5x per
    // second (trailing edge, so the final position after a seek/pause is
    // never lost).
    _subs.add(_player.stream.position.listen((p) {
      _lastPos = p;
      _posTimer ??= Timer(const Duration(milliseconds: 200), () {
        _posTimer = null;
        _position.value = _lastPos;
      });
    }));

    _subs.add(widget.engine.stateStream.listen((s) {
      _engineState.value = s;
    }));

    _dlTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => _refreshDownloaded());

    _initAndOpen();
    _loadOnlineSubtitles();
  }

  Future<void> _initAndOpen() async {
    // media_kit hardcodes network-timeout=5 for every Player it creates,
    // silently overriding mpv's own upstream default of 60 s. 5 s is far too
    // tight for a torrent stream (the first piece for byte 0 can legitimately
    // take longer), so restore mpv's real default. setProperty lives on
    // NativePlayer, reached through Player.platform.
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('network-timeout', '60');

      // When the cache runs dry mpv pauses and resumes after only 1 s of data
      // (default) - on a marginal swarm it flaps between "buffering" and
      // "playing" every few seconds. Wait for a real cushion instead.
      await platform.setProperty('cache-pause-wait', '8');

      // Keep only 16 MiB of already-played data (bufferSize applies to both
      // directions) so the bigger read-ahead doesn't double RAM.
      await platform.setProperty('demuxer-max-back-bytes', '16777216');
    }
    await _openStream();
  }

  Future<void> _openStream() async {
    try {
      // streamUrl is already a full HTTP URL served by InTorrent's native
      // layer (range-request server) - open it directly.
      await _player.open(Media(widget.streamUrl));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _posTimer?.cancel();
    _dlTimer?.cancel();
    _hudTimer?.cancel();
    _chainTimer?.cancel();
    _unlockTimer?.cancel();

    _position.dispose();
    _duration.dispose();
    _downloadedUpTo.dispose();
    _dragValue.dispose();
    _engineState.dispose();
    _hud.dispose();
    _online.dispose();

    _player.dispose();
    widget.engine.stop(); // stop torrent + clean temp files
    super.dispose();
  }

  // ── Controls visibility ────────────────────────────────────────────────────

  /// Auto-hide is only allowed while actually playing and idle.
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing || _busy || _menuOpen || _scrubbing || _locked) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _refreshDownloaded() async {
    if (!mounted || !_controlsShown) return;
    final v = await widget.engine
        .downloadedUpTo(_position.value, _duration.value);
    if (mounted) _downloadedUpTo.value = v;
  }

  // ── Playback actions ───────────────────────────────────────────────────────

  void _togglePlay() {
    if (_completed) {
      _player.seek(Duration.zero);
      _player.play();
    } else if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _scheduleHide();
  }

  void _seekTo(Duration target) {
    final dur = _duration.value;
    var clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (dur > Duration.zero && clamped > dur) clamped = dur;
    _player.seek(clamped);
    _position.value = clamped;
    widget.engine.onUserSeek(duration: dur);
  }

  void _seekBy(int seconds) {
    _seekTo(_player.state.position + Duration(seconds: seconds));
  }

  void _seekToFraction(double fraction) {
    final dur = _duration.value;
    if (dur <= Duration.zero) return;
    _seekTo(Duration(milliseconds: (dur.inMilliseconds * fraction).round()));
  }

  void _setRate(double rate) {
    setState(() => _rate = rate);
    _player.setRate(rate);
  }

  void _showHud(IconData icon, String text) {
    _hud.value = _HudInfo(icon, text);
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 800), () {
      _hud.value = null;
    });
  }

  // ── Gestures ───────────────────────────────────────────────────────────────

  void _onTap() {
    if (_locked) {
      setState(() => _unlockHint = true);
      _unlockTimer?.cancel();
      _unlockTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _unlockHint = false);
      });
      return;
    }
    // Rapid taps after a double-tap keep seeking (YouTube behaviour).
    if (_chainTimer?.isActive ?? false) {
      _handleSeekTap();
      return;
    }
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
      _hideTimer?.cancel();
    } else {
      _showControls();
    }
  }

  void _onDoubleTap() {
    if (_locked) return;
    _handleSeekTap();
  }

  void _handleSeekTap() {
    final width = MediaQuery.sizeOf(context).width;
    final x = _lastTapX;
    final side = x < width * 0.4 ? -1 : (x > width * 0.6 ? 1 : 0);
    if (side == 0) {
      _togglePlay();
      return;
    }
    if (side != _rippleSide) _chainSeconds = 0;
    _chainSeconds += 10;
    _seekBy(side * 10);
    setState(() => _rippleSide = side);
    _chainTimer?.cancel();
    _chainTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _rippleSide = 0;
          _chainSeconds = 0;
        });
      }
    });
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (_locked) return;
    _rateBeforeHold = _rate;
    _player.setRate(2.0);
    _hud.value = const _HudInfo(Icons.fast_forward_rounded, '2x speed');
    _hudTimer?.cancel();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_locked) return;
    _player.setRate(_rateBeforeHold);
    _hud.value = null;
  }

  void _onVDragStart(DragStartDetails details) {
    if (_locked) return;
    final width = MediaQuery.sizeOf(context).width;
    _dragOnRight = details.localPosition.dx > width / 2;
    _volAtDragStart = _player.state.volume;
    _volDragAccum = 0;
  }

  void _onVDragUpdate(DragUpdateDetails details) {
    if (_locked || !_dragOnRight) return;
    final height = MediaQuery.sizeOf(context).height;
    _volDragAccum -= details.delta.dy;
    final v = (_volAtDragStart + _volDragAccum / (height * 0.7) * 100)
        .clamp(0.0, 100.0)
        .toDouble();
    _player.setVolume(v);
    _showHud(
      v == 0
          ? Icons.volume_off_rounded
          : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
      '${v.round()}%',
    );
  }

  // ── Menus ──────────────────────────────────────────────────────────────────

  // ── Online English subtitles ───────────────────────────────────────────────

  /// Title given to online tracks, so they can be told apart from the file's
  /// own (embedded) tracks in the track list.
  static const String _onlineTitlePrefix = 'English (online';

  bool _isOnlineTrack(SubtitleTrack t) =>
      (t.title ?? '').startsWith(_onlineTitlePrefix);

  /// Asks the subtitle service for English subtitles matching this video. Runs
  /// once when the player opens (one small request) and again on "try again".
  Future<void> _loadOnlineSubtitles() async {
    final query = widget.subtitleQuery;
    if (query == null) return;
    _online.value = const _OnlineSubs(_OnlineStatus.loading);
    try {
      final withFile = query.withFile(
        fileName: widget.engine.streamFileName,
        videoSize: widget.engine.streamFileSize,
      );
      final subs = await SubtitleService.fetchEnglish(withFile);
      if (!mounted) return;
      _online.value = _OnlineSubs(_OnlineStatus.ready, subs);
    } catch (e) {
      debugPrint('[TorrentPlayerScreen] online subtitles failed: $e');
      if (!mounted) return;
      _online.value = const _OnlineSubs(_OnlineStatus.error);
    }
  }

  Future<void> _useOnlineSubtitle(int index) async {
    final subs = _online.value.subs;
    if (index < 0 || index >= subs.length) return;
    await _player.setSubtitleTrack(SubtitleTrack.uri(
      subs[index].url,
      title: '$_onlineTitlePrefix ${index + 1})',
      language: 'eng',
    ));
    if (mounted) setState(() => _activeOnline = index);
  }

  /// mpv `sub-delay`: positive = subtitles appear LATER, negative = earlier.
  Future<void> _setSubDelay(double seconds) async {
    final rounded = (seconds * 10).round() / 10; // 0.1 s steps, no float drift
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('sub-delay', rounded.toStringAsFixed(1));
    }
    if (mounted) setState(() => _subDelay = rounded);
  }

  String _delayLabel(double v) =>
      v == 0 ? 'In sync' : '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} s';

  Future<void> _openSheet(WidgetBuilder builder) async {
    setState(() => _menusOpen++);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _sheetBg,
      barrierColor: Colors.black54,
      constraints: BoxConstraints(
        maxWidth: 480,
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: builder,
    );
    if (!mounted) return;
    setState(() => _menusOpen--);
    _scheduleHide();
  }

  Future<void> _openSettingsSheet() => _openSheet((ctx) {
        return StreamBuilder<Track>(
          stream: _player.stream.track,
          initialData: _player.state.track,
          builder: (context, snap) {
            final track = snap.data ?? _player.state.track;
            final tracks = _player.state.tracks;
            return _SheetScaffold(
              title: 'Settings',
              children: [
                _SheetRow(
                  icon: Icons.speed_rounded,
                  label: 'Playback speed',
                  value: _rateLabel(_rate),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openSpeedSheet();
                  },
                ),
                _SheetRow(
                  icon: Icons.audiotrack_rounded,
                  label: 'Audio',
                  value: _selectedAudioLabel(tracks, track),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openAudioSheet();
                  },
                ),
                _SheetRow(
                  icon: Icons.closed_caption_rounded,
                  label: 'Subtitles',
                  value: _selectedSubtitleLabel(tracks, track),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openSubtitleSheet();
                  },
                ),
              ],
            );
          },
        );
      });

  Future<void> _openSpeedSheet() => _openSheet((ctx) {
        return _SheetScaffold(
          title: 'Playback speed',
          children: [
            for (final s in _speeds)
              _SheetRow(
                label: _rateLabel(s),
                selected: s == _rate,
                onTap: () {
                  _setRate(s);
                  Navigator.pop(ctx);
                },
              ),
          ],
        );
      });

  Future<void> _openAudioSheet() => _openSheet((ctx) {
        return StreamBuilder<Tracks>(
          stream: _player.stream.tracks,
          initialData: _player.state.tracks,
          builder: (context, tracksSnap) {
            return StreamBuilder<Track>(
              stream: _player.stream.track,
              initialData: _player.state.track,
              builder: (context, trackSnap) {
                final tracks = tracksSnap.data ?? _player.state.tracks;
                final selected = (trackSnap.data ?? _player.state.track).audio;
                final audios = tracks.audio
                    .where((t) => t.id != 'auto' && t.id != 'no')
                    .toList();
                return _SheetScaffold(
                  title: 'Audio',
                  children: [
                    if (audios.isEmpty)
                      const _SheetNote('No separate audio tracks in this file.'),
                    for (var i = 0; i < audios.length; i++)
                      _SheetRow(
                        label: _trackLabel(
                            audios[i].title, audios[i].language, i + 1),
                        sublabel: _audioDetail(audios[i]),
                        selected: selected.id == audios[i].id,
                        onTap: () {
                          _player.setAudioTrack(audios[i]);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                );
              },
            );
          },
        );
      });

  Future<void> _openSubtitleSheet() => _openSheet((ctx) {
        return StatefulBuilder(builder: (context, setSheet) {
          return StreamBuilder<Tracks>(
            stream: _player.stream.tracks,
            initialData: _player.state.tracks,
            builder: (context, tracksSnap) {
              return StreamBuilder<Track>(
                stream: _player.stream.track,
                initialData: _player.state.track,
                builder: (context, trackSnap) {
                  final tracks = tracksSnap.data ?? _player.state.tracks;
                  final selected =
                      (trackSnap.data ?? _player.state.track).subtitle;
                  final subs = tracks.subtitle
                      .where((t) =>
                          t.id != 'auto' && t.id != 'no' && !_isOnlineTrack(t))
                      .toList();
                  return _SheetScaffold(
                    title: 'Subtitles',
                    children: [
                      _SheetRow(
                        label: 'Off',
                        selected: selected.id == 'no',
                        onTap: () {
                          _player.setSubtitleTrack(SubtitleTrack.no());
                          setState(() => _activeOnline = null);
                          Navigator.pop(ctx);
                        },
                      ),
                      if (subs.isEmpty)
                        const _SheetNote(
                            'This file has no embedded subtitle tracks.'),
                      for (var i = 0; i < subs.length; i++)
                        _SheetRow(
                          label: _trackLabel(
                              subs[i].title, subs[i].language, i + 1),
                          sublabel: _isImageSubtitle(subs[i])
                              ? 'Image-based (PGS/DVD) - cannot be displayed yet'
                              : null,
                          dim: _isImageSubtitle(subs[i]),
                          selected: selected.id == subs[i].id,
                          onTap: () {
                            _player.setSubtitleTrack(subs[i]);
                            setState(() => _activeOnline = null);
                            Navigator.pop(ctx);
                          },
                        ),

                      // ── Online English subtitles ─────────────────────────
                      const Divider(color: Colors.white12, height: 24),
                      const _SheetLabel('ONLINE  ·  ENGLISH'),
                      ValueListenableBuilder<_OnlineSubs>(
                        valueListenable: _online,
                        builder: (context, online, _) {
                          final currentIsOnline = tracks.subtitle.any(
                              (t) => t.id == selected.id && _isOnlineTrack(t));
                          switch (online.status) {
                            case _OnlineStatus.idle:
                              return const _SheetNote(
                                  'Online subtitles are not available for this video.');
                            case _OnlineStatus.loading:
                              return const _SheetNote(
                                  'Searching for English subtitles...');
                            case _OnlineStatus.error:
                              return _SheetRow(
                                icon: Icons.refresh_rounded,
                                label: 'Could not reach the subtitle service',
                                sublabel: 'Tap to try again',
                                onTap: _loadOnlineSubtitles,
                              );
                            case _OnlineStatus.ready:
                              if (online.subs.isEmpty) {
                                return const _SheetNote(
                                    'No English subtitles found online for this title.');
                              }
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var i = 0; i < online.subs.length; i++)
                                    _SheetRow(
                                      label: 'English · Option ${i + 1}',
                                      sublabel: i == 0
                                          ? 'Best match - if the timing is off, try another option or use Timing below'
                                          : null,
                                      selected:
                                          currentIsOnline && _activeOnline == i,
                                      onTap: () {
                                        _useOnlineSubtitle(i);
                                        Navigator.pop(ctx);
                                      },
                                    ),
                                ],
                              );
                          }
                        },
                      ),

                      const Divider(color: Colors.white12, height: 24),
                      const _SheetLabel('Size'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (var i = 0; i < _sizeNames.length; i++)
                              _OptionChip(
                                label: _sizeNames[i],
                                selected: _subScale == _sizeValues[i],
                                onTap: () {
                                  setState(() => _subScale = _sizeValues[i]);
                                  setSheet(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                      const _SheetLabel('Style'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            _OptionChip(
                              label: 'Box',
                              selected: _subBackground,
                              onTap: () {
                                setState(() => _subBackground = true);
                                setSheet(() {});
                              },
                            ),
                            _OptionChip(
                              label: 'Outline',
                              selected: !_subBackground,
                              onTap: () {
                                setState(() => _subBackground = false);
                                setSheet(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      const _SheetLabel('Timing  (Later = subtitles appear later)'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Row(
                          children: [
                            _OptionChip(
                              label: 'Earlier',
                              selected: false,
                              onTap: () async {
                                await _setSubDelay(_subDelay - 0.5);
                                setSheet(() {});
                              },
                            ),
                            const SizedBox(width: 8),
                            _OptionChip(
                              label: 'Later',
                              selected: false,
                              onTap: () async {
                                await _setSubDelay(_subDelay + 0.5);
                                setSheet(() {});
                              },
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _delayLabel(_subDelay),
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            if (_subDelay != 0)
                              _OptionChip(
                                label: 'Reset',
                                selected: false,
                                onTap: () async {
                                  await _setSubDelay(0);
                                  setSheet(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        });
      });

  static const List<double> _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const List<String> _sizeNames = ['Small', 'Medium', 'Large', 'Huge'];
  static const List<double> _sizeValues = [0.8, 1.0, 1.3, 1.6];

  String _selectedAudioLabel(Tracks tracks, Track current) {
    final audios =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    for (var i = 0; i < audios.length; i++) {
      if (audios[i].id == current.audio.id) {
        return _trackLabel(audios[i].title, audios[i].language, i + 1);
      }
    }
    return audios.isEmpty ? 'Default' : 'Auto';
  }

  String _selectedSubtitleLabel(Tracks tracks, Track current) {
    if (current.subtitle.id == 'no') return 'Off';
    for (final t in tracks.subtitle) {
      if (t.id == current.subtitle.id && _isOnlineTrack(t)) {
        return 'English (online)';
      }
    }
    final subs = tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no' && !_isOnlineTrack(t))
        .toList();
    for (var i = 0; i < subs.length; i++) {
      if (subs[i].id == current.subtitle.id) {
        return _trackLabel(subs[i].title, subs[i].language, i + 1);
      }
    }
    if (subs.isEmpty) {
      return _online.value.subs.isNotEmpty ? 'Online available' : 'None available';
    }
    return 'Auto';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildErrorScreen();

    final shown = _controlsShown;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Video only - media_kit's own controls and subtitle view are
          //    switched off; we draw both.
          Video(
            controller: _controller,
            controls: NoVideoControls,
            fill: Colors.black,
            subtitleViewConfiguration:
                const SubtitleViewConfiguration(visible: false),
          ),

          // 2. Subtitles (lift above the controls while they're visible).
          _SubtitleLayer(
            player: _player,
            bottom: shown ? 96 : 28,
            scale: _subScale,
            background: _subBackground,
          ),

          // 3. Gesture layer (sits below the controls so buttons win).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _lastTapX = d.localPosition.dx,
              onTap: _onTap,
              onDoubleTapDown: (d) => _lastTapX = d.localPosition.dx,
              onDoubleTap: _onDoubleTap,
              onLongPressStart: _onLongPressStart,
              onLongPressEnd: _onLongPressEnd,
              onVerticalDragStart: _onVDragStart,
              onVerticalDragUpdate: _onVDragUpdate,
            ),
          ),

          // 4. Double-tap seek feedback.
          if (_rippleSide != 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Row(
                  children: [
                    Expanded(
                      child: _rippleSide < 0
                          ? _SeekRipple(left: true, seconds: _chainSeconds)
                          : const SizedBox.shrink(),
                    ),
                    Expanded(
                      child: _rippleSide > 0
                          ? _SeekRipple(left: false, seconds: _chainSeconds)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),

          // 5. Controls.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !shown,
              child: AnimatedOpacity(
                opacity: shown ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: _buildControls(),
              ),
            ),
          ),

          // 6. Lock hint.
          if (_locked && _unlockHint)
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _locked = false;
                      _unlockHint = false;
                    });
                    _showControls();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_open_rounded,
                            color: _accent, size: 16),
                        SizedBox(width: 8),
                        Text('Tap to unlock',
                            style: TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 7. Volume / 2x indicator.
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<_HudInfo?>(
                valueListenable: _hud,
                builder: (context, hud, _) {
                  if (hud == null) return const SizedBox.shrink();
                  return Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 28),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(hud.icon, color: Colors.white, size: 18),
                            const SizedBox(width: 8),
                            Text(hud.text,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Stack(
      children: [
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(child: _Gradient(fromTop: true, height: 110)),
        ),
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(child: _Gradient(fromTop: false, height: 150)),
        ),

        // ── Top bar ──────────────────────────────────────────────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: Colors.white,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: IgnorePointer(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(blurRadius: 6, color: Colors.black54)
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _QualityBadge(quality: widget.quality),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TorrentState>(
                    valueListenable: _engineState,
                    builder: (context, s, _) => _EngineHud(state: s),
                  ),
                  ValueListenableBuilder<_OnlineSubs>(
                    valueListenable: _online,
                    builder: (context, online, _) {
                      // Small dot = English subtitles were found online and
                      // none is switched on yet.
                      final hint = online.status == _OnlineStatus.ready &&
                          online.subs.isNotEmpty &&
                          _activeOnline == null;
                      return IconButton(
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Icon(Icons.closed_caption_rounded),
                            if (hint)
                              Positioned(
                                right: -2,
                                top: -2,
                                child: Container(
                                  width: 9,
                                  height: 9,
                                  decoration: const BoxDecoration(
                                    color: _accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        color: Colors.white,
                        tooltip: 'Subtitles',
                        onPressed: _openSubtitleSheet,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_rounded),
                    color: Colors.white,
                    tooltip: 'Settings',
                    onPressed: _openSettingsSheet,
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── Centre: replay10 / play-pause (or spinner) / forward10 ──────
        Center(child: _buildCenter()),

        // ── Bottom: seek bar + time + actions ────────────────────────────
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _SeekBar(
                      position: _position,
                      duration: _duration,
                      downloaded: _downloadedUpTo,
                      dragValue: _dragValue,
                      onScrubStart: () {
                        setState(() => _scrubbing = true);
                        _hideTimer?.cancel();
                      },
                      onScrubEnd: (fraction) {
                        setState(() => _scrubbing = false);
                        if (fraction != null) _seekToFraction(fraction);
                        _scheduleHide();
                      },
                    ),
                  ),
                  Row(
                    children: [
                      IgnorePointer(
                        child: _TimeLabel(
                          position: _position,
                          duration: _duration,
                          dragValue: _dragValue,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.lock_open_rounded, size: 22),
                        color: Colors.white,
                        tooltip: 'Lock controls',
                        onPressed: () {
                          setState(() {
                            _locked = true;
                            _unlockHint = false;
                          });
                          _hideTimer?.cancel();
                        },
                      ),
                      TextButton(
                        onPressed: _openSpeedSheet,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size(48, 40),
                        ),
                        child: Text(
                          _rateLabel(_rate),
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCenter() {
    final IconData mainIcon = _completed
        ? Icons.replay_rounded
        : (_playing ? Icons.pause_rounded : Icons.play_arrow_rounded);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleButton(
              icon: Icons.replay_10_rounded,
              size: 52,
              iconSize: 28,
              onTap: () {
                _seekBy(-10);
                _scheduleHide();
              },
            ),
            const SizedBox(width: 36),
            SizedBox(
              width: 72,
              height: 72,
              child: _busy
                  ? const Center(
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: CircularProgressIndicator(
                            strokeWidth: 3.5, color: _accent),
                      ),
                    )
                  : _CircleButton(
                      icon: mainIcon,
                      size: 72,
                      iconSize: 44,
                      onTap: _togglePlay,
                    ),
            ),
            const SizedBox(width: 36),
            _CircleButton(
              icon: Icons.forward_10_rounded,
              size: 52,
              iconSize: 28,
              onTap: () {
                _seekBy(10);
                _scheduleHide();
              },
            ),
          ],
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: IgnorePointer(
              child: ValueListenableBuilder<TorrentState>(
                valueListenable: _engineState,
                builder: (context, s, _) => Text(
                  'Buffering  •  ${s.peers} peers  •  '
                  '${s.downloadSpeedMbs.toStringAsFixed(1)} MB/s',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildErrorScreen() {
    final isCodec = _error != null &&
        (_error!.contains('EXCEEDS_CAPABILITIES') ||
            _error!.contains('hevc') ||
            _error!.contains('hvc') ||
            _error!.contains('VideoError'));

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                Text(
                  isCodec
                      ? 'Your device cannot decode this codec.\nTry opening in an external player.'
                      : (_error ?? 'Playback error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 14),
                ),
                const SizedBox(height: 24),
                if (isCodec)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open in External Player',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12)),
                    onPressed: () async {
                      final uri = Uri.parse(widget.streamUrl);
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }
                    },
                  ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back',
                      style: TextStyle(color: Colors.white38)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String _rateLabel(double r) =>
    r == r.roundToDouble() ? '${r.toInt()}x' : '${r}x';

const Map<String, String> _languageNames = {
  'en': 'English', 'eng': 'English',
  'hi': 'Hindi', 'hin': 'Hindi',
  'ta': 'Tamil', 'tam': 'Tamil',
  'te': 'Telugu', 'tel': 'Telugu',
  'ml': 'Malayalam', 'mal': 'Malayalam',
  'kn': 'Kannada', 'kan': 'Kannada',
  'bn': 'Bengali', 'ben': 'Bengali',
  'mr': 'Marathi', 'mar': 'Marathi',
  'pa': 'Punjabi', 'pan': 'Punjabi',
  'gu': 'Gujarati', 'guj': 'Gujarati',
  'ur': 'Urdu', 'urd': 'Urdu',
  'ne': 'Nepali', 'nep': 'Nepali',
  'si': 'Sinhala', 'sin': 'Sinhala',
  'es': 'Spanish', 'spa': 'Spanish',
  'fr': 'French', 'fre': 'French', 'fra': 'French',
  'de': 'German', 'ger': 'German', 'deu': 'German',
  'it': 'Italian', 'ita': 'Italian',
  'pt': 'Portuguese', 'por': 'Portuguese',
  'ru': 'Russian', 'rus': 'Russian',
  'ja': 'Japanese', 'jpn': 'Japanese',
  'ko': 'Korean', 'kor': 'Korean',
  'zh': 'Chinese', 'chi': 'Chinese', 'zho': 'Chinese',
  'ar': 'Arabic', 'ara': 'Arabic',
  'tr': 'Turkish', 'tur': 'Turkish',
  'id': 'Indonesian', 'ind': 'Indonesian',
  'ms': 'Malay', 'may': 'Malay', 'msa': 'Malay',
  'th': 'Thai', 'tha': 'Thai',
  'vi': 'Vietnamese', 'vie': 'Vietnamese',
  'nl': 'Dutch', 'dut': 'Dutch', 'nld': 'Dutch',
  'pl': 'Polish', 'pol': 'Polish',
  'sv': 'Swedish', 'swe': 'Swedish',
  'uk': 'Ukrainian', 'ukr': 'Ukrainian',
  'fa': 'Persian', 'per': 'Persian', 'fas': 'Persian',
  'he': 'Hebrew', 'heb': 'Hebrew',
};

/// "Hindi" / "Hindi · DD 5.1" / "Track 2" from whatever mpv reports.
String _trackLabel(String? title, String? language, int index) {
  final lang = _languageNames[(language ?? '').toLowerCase().trim()];
  final t = (title ?? '').trim();
  if (lang != null && t.isNotEmpty) {
    return t.toLowerCase().contains(lang.toLowerCase()) ? t : '$lang · $t';
  }
  if (lang != null) return lang;
  if (t.isNotEmpty) return t;
  final raw = (language ?? '').trim();
  return raw.isNotEmpty ? raw.toUpperCase() : 'Track $index';
}

String? _audioDetail(AudioTrack t) {
  final parts = <String>[];
  final codec = (t.codec ?? '').trim();
  final channels = (t.channels ?? '').trim();
  if (codec.isNotEmpty) parts.add(codec.toUpperCase());
  if (channels.isNotEmpty) parts.add(channels);
  return parts.isEmpty ? null : parts.join(' · ');
}

const List<String> _imageSubtitleCodecs = [
  'pgs',
  'hdmv',
  'dvd_subtitle',
  'dvdsub',
  'dvb_subtitle',
  'dvbsub',
  'vobsub',
];

bool _isImageSubtitle(SubtitleTrack t) {
  final codec = (t.codec ?? '').toLowerCase();
  if (codec.isEmpty) return false;
  return _imageSubtitleCodecs.any(codec.contains);
}

enum _OnlineStatus { idle, loading, ready, error }

class _OnlineSubs {
  final _OnlineStatus status;
  final List<OnlineSubtitle> subs;
  const _OnlineSubs(this.status, [this.subs = const []]);
}

class _HudInfo {
  final IconData icon;
  final String text;
  const _HudInfo(this.icon, this.text);
}

// ── Subtitle layer ────────────────────────────────────────────────────────────

class _SubtitleLayer extends StatelessWidget {
  final Player player;
  final double bottom;
  final double scale;
  final bool background;

  const _SubtitleLayer({
    required this.player,
    required this.bottom,
    required this.scale,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: StreamBuilder<List<String>>(
          stream: player.stream.subtitle,
          initialData: player.state.subtitle,
          builder: (context, snap) {
            final text = [
              for (final line in snap.data ?? const <String>[])
                if (line.trim().isNotEmpty) line.trim(),
            ].join('\n');

            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: EdgeInsets.fromLTRB(56, 0, 56, bottom),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: text.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: background
                            ? BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.62),
                                borderRadius: BorderRadius.circular(4),
                              )
                            : null,
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18 * scale,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                            shadows: background
                                ? null
                                : const [
                                    Shadow(blurRadius: 3, color: Colors.black),
                                    Shadow(
                                        offset: Offset(1, 1),
                                        blurRadius: 2,
                                        color: Colors.black),
                                    Shadow(
                                        offset: Offset(-1, -1),
                                        blurRadius: 2,
                                        color: Colors.black),
                                  ],
                          ),
                        ),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── Seek bar ──────────────────────────────────────────────────────────────────

class _SeekBar extends StatelessWidget {
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueListenable<double> downloaded;
  final ValueNotifier<double?> dragValue;
  final VoidCallback onScrubStart;
  final ValueChanged<double?> onScrubEnd;

  const _SeekBar({
    required this.position,
    required this.duration,
    required this.downloaded,
    required this.dragValue,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double frac(double dx) =>
            width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0).toDouble();

        return SizedBox(
          height: 44,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    if (duration.value <= Duration.zero) return;
                    onScrubEnd(frac(d.localPosition.dx));
                  },
                  onHorizontalDragStart: (d) {
                    if (duration.value <= Duration.zero) return;
                    dragValue.value = frac(d.localPosition.dx);
                    onScrubStart();
                  },
                  onHorizontalDragUpdate: (d) {
                    if (dragValue.value == null) return;
                    dragValue.value = frac(d.localPosition.dx);
                  },
                  onHorizontalDragEnd: (_) {
                    final v = dragValue.value;
                    dragValue.value = null;
                    onScrubEnd(v);
                  },
                  onHorizontalDragCancel: () {
                    if (dragValue.value == null) return;
                    dragValue.value = null;
                    onScrubEnd(null);
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _SeekPainter(
                        position: position,
                        duration: duration,
                        downloaded: downloaded,
                        dragValue: dragValue,
                      ),
                    ),
                  ),
                ),
              ),
              // Time bubble while scrubbing.
              ValueListenableBuilder<double?>(
                valueListenable: dragValue,
                builder: (context, v, _) {
                  if (v == null) return const SizedBox.shrink();
                  final d = duration.value;
                  final t = Duration(
                      milliseconds: (d.inMilliseconds * v).round());
                  final maxLeft = (width - 64).clamp(0.0, width).toDouble();
                  final left = (v * width - 32).clamp(0.0, maxLeft).toDouble();
                  return Positioned(
                    left: left,
                    top: -34,
                    child: IgnorePointer(
                      child: Container(
                        width: 64,
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _fmt(t),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueListenable<double> downloaded;
  final ValueListenable<double?> dragValue;

  _SeekPainter({
    required this.position,
    required this.duration,
    required this.downloaded,
    required this.dragValue,
  }) : super(
          repaint: Listenable.merge([position, duration, downloaded, dragValue]),
        );

  @override
  void paint(Canvas canvas, Size size) {
    final durMs = duration.value.inMilliseconds;
    final drag = dragValue.value;
    final played = drag ??
        (durMs > 0
            ? (position.value.inMilliseconds / durMs).clamp(0.0, 1.0).toDouble()
            : 0.0);
    final dl = downloaded.value.clamp(0.0, 1.0).toDouble();

    final cy = size.height / 2;
    final h = drag != null ? 5.0 : 3.0;
    final r = Radius.circular(h / 2);

    RRect bar(double to) =>
        RRect.fromLTRBR(0, cy - h / 2, size.width * to, cy + h / 2, r);

    canvas.drawRRect(bar(1.0), Paint()..color = Colors.white24);
    canvas.drawRRect(
        bar(dl > played ? dl : played), Paint()..color = Colors.white54);
    canvas.drawRRect(bar(played), Paint()..color = _accent);
    canvas.drawCircle(Offset(size.width * played, cy), drag != null ? 9.0 : 6.5,
        Paint()..color = _accent);
  }

  @override
  bool shouldRepaint(covariant _SeekPainter oldDelegate) => false;
}

class _TimeLabel extends StatelessWidget {
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueListenable<double?> dragValue;

  const _TimeLabel({
    required this.position,
    required this.duration,
    required this.dragValue,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([position, duration, dragValue]),
      builder: (context, _) {
        final d = duration.value;
        final v = dragValue.value;
        final p = v != null
            ? Duration(milliseconds: (d.inMilliseconds * v).round())
            : position.value;
        return Text(
          '${_fmt(p)} / ${_fmt(d)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
          ),
        );
      },
    );
  }
}

// ── Small widgets ─────────────────────────────────────────────────────────────

class _Gradient extends StatelessWidget {
  final bool fromTop;
  final double height;
  const _Gradient({required this.fromTop, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: iconSize),
        ),
      ),
    );
  }
}

class _SeekRipple extends StatelessWidget {
  final bool left;
  final int seconds;
  const _SeekRipple({required this.left, required this.seconds});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.horizontal(
          left: left ? Radius.zero : const Radius.circular(200),
          right: left ? const Radius.circular(200) : Radius.zero,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              left ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
              color: Colors.white,
              size: 34,
            ),
            const SizedBox(height: 4),
            Text(
              '$seconds seconds',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    if (quality.trim().isEmpty) return const SizedBox.shrink();
    final color = quality.contains('4K') || quality.contains('HDR')
        ? const Color(0xFFa855f7)
        : quality.contains('1080')
            ? const Color(0xFF3b82f6)
            : const Color(0xFF22c55e);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(quality,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}

/// Live engine HUD — download speed while streaming, or prefetch progress.
class _EngineHud extends StatelessWidget {
  final TorrentState state;
  const _EngineHud({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.phase != TorrentPhase.streaming) return const SizedBox();
    final label = state.prefetching
        ? 'Prefetch ${(state.prefetchPct * 100).round()}%'
        : '${state.downloadSpeedMbs.toStringAsFixed(1)} MB/s';
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF22c55e).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: const Color(0xFF22c55e).withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download_rounded,
              color: Color(0xFF22c55e), size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
                color: Color(0xFF22c55e),
                fontSize: 10,
                fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// ── Sheet widgets ─────────────────────────────────────────────────────────────

class _SheetScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SheetScaffold({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
            ),
            ...children,
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String? sublabel;
  final String? value;
  final bool selected;
  final bool dim;
  final VoidCallback onTap;

  const _SheetRow({
    this.icon,
    required this.label,
    this.sublabel,
    this.value,
    this.selected = false,
    this.dim = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = dim
        ? Colors.white38
        : (selected ? _accent : Colors.white);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white70, size: 22),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (sublabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        sublabel!,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null)
              Text(value!,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13)),
            if (selected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.check_rounded, color: _accent, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5),
      ),
    );
  }
}

class _SheetNote extends StatelessWidget {
  final String text;
  const _SheetNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(text,
          style: const TextStyle(color: Colors.white38, fontSize: 13)),
    );
  }
}

class _OptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _OptionChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _accent : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
