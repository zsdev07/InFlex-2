import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/torrent_engine.dart';

// ── TorrentPlayerScreen ───────────────────────────────────────────────────────
//
// Screen 2 of 2 in the P2P flow.
//
// Receives the localhost stream URL from TorrentLoadingScreen after the
// engine signals TorrentPhase.ready. Also receives the TorrentEngine
// reference so it can:
//   • Report playback position for the sliding window
//   • Stop the engine cleanly on dispose
//
// Player: media_kit — handles HEVC/H.265, MKV, HDR natively on Android.
//
// UI: Glassmorphism overlay with:
//   • Top bar: back button + title + quality badge
//   • Center: tap zones (left=rewind, center=play/pause, right=forward)
//   • Bottom bar: progress scrubber + time + speed + lock controls
//   • Codec error fallback: "Open in External Player" button

class TorrentPlayerScreen extends StatefulWidget {
  final String streamUrl;
  final String title;
  final String quality;
  final TorrentEngine engine;

  const TorrentPlayerScreen({
    super.key,
    required this.streamUrl,
    required this.title,
    required this.quality,
    required this.engine,
  });

  @override
  State<TorrentPlayerScreen> createState() => _TorrentPlayerScreenState();
}

class _TorrentPlayerScreenState extends State<TorrentPlayerScreen>
    with SingleTickerProviderStateMixin {
  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<TorrentState>? _engineSub;
  Timer? _overlayTimer;

  bool _showOverlay = true;
  bool _locked = false;
  double _playbackSpeed = 1.0;
  String? _error;

  // Engine state for the HUD
  TorrentState _engineState =
      const TorrentState(phase: TorrentPhase.streaming);

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
        // Bumped from default (none) purely for debugging the ~5s
        // silent-stop issue — mpv's own log is the only place that
        // will show a demuxer/probe/cache-pause reason that never
        // reaches _player.stream.error. Dial back to .warn once
        // this is diagnosed; verbose logging is noisy in normal use.
        logLevel: MPVLogLevel.debug,
      ),
    );
    _controller = VideoController(_player);

    _player.stream.error.listen((err) {
      // ignore: avoid_print
      print('[TorrentPlayerScreen] player error: $err');
      if (mounted) {
        setState(() => _error = err);
      }
    });

    // mpv's own log — this is the one channel that can explain a
    // stop/pause that never surfaces on stream.error (e.g. demuxer
    // probe failures, cache-pause, EOF-vs-underrun). Not filtered by
    // level here on purpose so nothing gets missed while we're
    // hunting for the 5s cutoff.
    _player.stream.log.listen((log) {
      // ignore: avoid_print
      print('[mpv:${log.level}] ${log.prefix}: ${log.text}');
    });

    // Correlate mpv's playing/buffering transitions against wall-clock
    // time and download progress, so we can line this up against the
    // wakelock-drop timestamp in logcat.
    _player.stream.buffering.listen((buffering) {
      // ignore: avoid_print
      print('[TorrentPlayerScreen] buffering=$buffering '
          'pos=${_player.state.position} at ${DateTime.now()}');
    });
    _player.stream.playing.listen((playing) {
      // ignore: avoid_print
      print('[TorrentPlayerScreen] playing=$playing '
          'pos=${_player.state.position} at ${DateTime.now()}');
    });

    // Listen to engine state for live HUD
    _engineSub = widget.engine.stateStream.listen((s) {
      if (mounted) setState(() => _engineState = s);
    });

    _startHideTimer();
    _initAndOpen();
  }

  Future<void> _initAndOpen() async {
    // media_kit hardcodes network-timeout=5 for every Player it creates
    // (see media_kit's player/native/player/real.dart) - silently
    // overriding mpv's own upstream default of 60s. That 5s figure is
    // media_kit's, not mpv's or ours: confirmed via mpv's source
    // (stream/network.c: `.timeout = 60`, no runtime-immutability flag
    // on the option) and via media_kit's own source (the override is
    // applied exactly once at player-creation time, never reapplied on
    // open(), so setting it here - once, before the first open() -
    // holds for this player's whole lifetime).
    //
    // 5s is far too tight for a torrent stream: the very first piece a
    // freshly-connecting swarm needs to serve byte 0 can legitimately
    // take longer than that depending on peer luck, with nothing wrong
    // on our end - confirmed in testing, where mpv aborted with
    // "Failed to open" at a precise ~5.1s mark even while the swarm was
    // healthy and downloading fine, or (separately) even before any
    // piece had completed at all. Restoring mpv's own real default
    // rather than picking an arbitrary number.
    //
    // setProperty isn't on Player itself - it's declared on NativePlayer
    // (media_kit's concrete platform implementation), reached through
    // Player's public `platform` field (typed as the abstract
    // PlatformPlayer, which doesn't declare it either). Hence the type
    // check below instead of calling it directly on _player.
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('network-timeout', '60');
    }
    await _openStream();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _overlayTimer?.cancel();
    _engineSub?.cancel();

    _player.dispose();
    widget.engine.stop(); // stop torrent + clean temp files
    super.dispose();
  }

  Future<void> _openStream() async {
    try {
      // widget.streamUrl is already a full HTTP URL served by
      // InTorrent's native layer (Range-request server that blocks
      // until requested bytes are downloaded) — open it directly, no
      // file:// wrapping needed.
      await _player.open(Media(widget.streamUrl));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _startHideTimer() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_locked) {
        setState(() => _showOverlay = false);
      }
    });
  }

  void _resetTimer() {
    setState(() => _showOverlay = true);
    _startHideTimer();
  }

  void _handleTap(TapDownDetails details) {
    if (_locked) {
      setState(() => _showOverlay = !_showOverlay);
      return;
    }
    final sw = MediaQuery.of(context).size.width;
    final x = details.localPosition.dx;
    if (x < sw * 0.3) {
      _seek(-10);
    } else if (x > sw * 0.7) {
      _seek(10);
    } else {
      _togglePlay();
    }
    _resetTimer();
  }

  void _togglePlay() {
    _player.state.playing ? _player.pause() : _player.play();
    setState(() {});
  }

  void _seek(int seconds) {
    final pos = _player.state.position;
    final dur = _player.state.duration;
    final newPos = pos + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : newPos > dur
            ? dur
            : newPos;
    _player.seek(clamped);
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildErrorScreen();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // ── Video surface ──────────────────────────────────────────
            SizedBox.expand(
              child: Video(controller: _controller),
            ),

            // ── Overlay ────────────────────────────────────────────────
            AnimatedOpacity(
              opacity: _showOverlay ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: _buildOverlay(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlay() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final dur = _player.state.duration;
        final prog =
            dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0;
        final playing = _player.state.playing;

        return Stack(
          children: [
            // Top gradient
            Positioned(
              top: 0, left: 0, right: 0,
              child: _GlassGradient(fromTop: true, height: 130),
            ),
            // Bottom gradient
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _GlassGradient(fromTop: false, height: 160),
            ),

            // ── Top bar ────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      _GlassButton(
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('NOW PLAYING',
                                style: TextStyle(
                                    color: Color(0xFFFFCC00),
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5)),
                            Text(widget.title,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      // Quality badge
                      _QualityBadge(quality: widget.quality),
                      const SizedBox(width: 8),
                      // Live engine HUD
                      _EngineHud(state: _engineState),
                    ],
                  ),
                ),
              ),
            ),

            // ── Center: seek indicators ────────────────────────────────
            if (!_locked)
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _SeekHint(icon: Icons.replay_10_rounded),
                    const SizedBox(width: 56),
                    GestureDetector(
                      onTap: _togglePlay,
                      child: _GlassCircle(
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                    const SizedBox(width: 56),
                    _SeekHint(icon: Icons.forward_10_rounded),
                  ],
                ),
              ),

            // ── Bottom bar ─────────────────────────────────────────────
            if (!_locked)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Time row
                        Row(
                          children: [
                            Text(_fmt(pos),
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                            const Spacer(),
                            Text(_fmt(dur),
                                style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Scrubber
                        SliderTheme(
                          data: SliderThemeData(
                            activeTrackColor: const Color(0xFFFFCC00),
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.15),
                            thumbColor: Colors.white,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape:
                                SliderComponentShape.noOverlay,
                            trackHeight: 3,
                          ),
                          child: Slider(
                            value: prog.clamp(0.0, 1.0),
                            onChanged: (v) {
                              _player.seek(Duration(
                                  milliseconds:
                                      (v * dur.inMilliseconds).round()));
                              _resetTimer();
                            },
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Controls row
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            // Speed picker
                            _SpeedButton(
                              speed: _playbackSpeed,
                              onSelect: (v) {
                                setState(() => _playbackSpeed = v);
                                _player.setRate(v);
                                _resetTimer();
                              },
                            ),
                            // Lock button
                            _GlassIconBtn(
                              icon: _locked
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              onTap: () {
                                setState(() => _locked = !_locked);
                                _resetTimer();
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── Lock overlay message ───────────────────────────────────
            if (_locked)
              Positioned(
                bottom: 32, left: 0, right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _locked = false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_rounded,
                              color: Color(0xFFFFCC00), size: 14),
                          SizedBox(width: 6),
                          Text('Tap to unlock',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 14),
                ),
                const SizedBox(height: 24),
                if (isCodec)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open in External Player',
                        style:
                            TextStyle(fontWeight: FontWeight.w800)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFCC00),
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

// ── Sub widgets ───────────────────────────────────────────────────────────────

class _GlassGradient extends StatelessWidget {
  final bool fromTop;
  final double height;
  const _GlassGradient(
      {required this.fromTop, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin:
              fromTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: fromTop
              ? Alignment.bottomCenter
              : Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.75),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _GlassCircle extends StatelessWidget {
  final Widget child;
  const _GlassCircle({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.2), width: 1.5),
      ),
      child: Center(child: child),
    );
  }
}

class _GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassIconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white60, size: 18),
      ),
    );
  }
}

class _SeekHint extends StatelessWidget {
  final IconData icon;
  const _SeekHint({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Icon(icon, color: Colors.white.withValues(alpha: 0.6),
        size: 28);
  }
}

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    final color = quality.contains('4K') || quality.contains('HDR')
        ? const Color(0xFFa855f7)
        : quality.contains('1080')
            ? const Color(0xFF3b82f6)
            : const Color(0xFF22c55e);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(quality,
          style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800)),
    );
  }
}

/// Live engine HUD — shows download speed while streaming
class _EngineHud extends StatelessWidget {
  final TorrentState state;
  const _EngineHud({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.phase != TorrentPhase.streaming) return const SizedBox();
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            '${state.downloadSpeedMbs.toStringAsFixed(1)} MB/s',
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

class _SpeedButton extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onSelect;
  const _SpeedButton(
      {required this.speed, required this.onSelect});

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF0E0E16),
          shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _speeds.map((s) {
                final sel = s == speed;
                return ListTile(
                  title: Text('${s}x',
                      style: TextStyle(
                          color: sel
                              ? const Color(0xFFFFCC00)
                              : Colors.white70,
                          fontWeight: sel
                              ? FontWeight.w800
                              : FontWeight.normal)),
                  trailing: sel
                      ? const Icon(Icons.check,
                          color: Color(0xFFFFCC00), size: 18)
                      : null,
                  onTap: () {
                    onSelect(s);
                    Navigator.pop(context);
                  },
                );
              }).toList(),
            ),
          ),
        );
      },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('${speed}x',
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}
