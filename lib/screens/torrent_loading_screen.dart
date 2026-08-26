import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/torrent_engine.dart';
import 'torrent_player_screen.dart';

// ── TorrentLoadingScreen ──────────────────────────────────────────────────────
//
// Screen 1 of 2 in the new P2P flow.
//
// Responsibilities:
//   1. Starts TorrentEngine with the given magnet link
//   2. Displays live buffering state (peers, speed, buffer %)
//   3. When engine reaches TorrentPhase.ready → pushReplacement to
//      TorrentPlayerScreen (Screen 2)
//   4. On error → shows error card with retry + back options
//   5. On back → stops engine, cleans up temp files
//
// Debug notes are shown in a collapsible card at the bottom.
// This separation from the player screen makes it easy to add
// debug output, error context, or custom messages here without
// touching the player.

class TorrentLoadingScreen extends StatefulWidget {
  final String magnetLink;
  final String movieTitle;
  final String quality;
  final String? debugNote; // optional custom note shown in debug card

  const TorrentLoadingScreen({
    super.key,
    required this.magnetLink,
    required this.movieTitle,
    required this.quality,
    this.debugNote,
  });

  @override
  State<TorrentLoadingScreen> createState() => _TorrentLoadingScreenState();
}

class _TorrentLoadingScreenState extends State<TorrentLoadingScreen>
    with SingleTickerProviderStateMixin {
  final _engine = TorrentEngine();
  StreamSubscription<TorrentState>? _sub;

  TorrentState _state = const TorrentState(phase: TorrentPhase.idle);
  bool _navigating = false;
  bool _debugExpanded = false;

  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _sub = _engine.stateStream.listen(_onState);
    _engine.start(widget.magnetLink);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    // NOTE: Do NOT call engine.stop() here — the player screen takes over.
    // Engine is only stopped if we actually go back (see _onBack).
    super.dispose();
  }

  void _onState(TorrentState state) {
    if (!mounted) return;
    setState(() => _state = state);

    // When ready → push to player screen (only once).
    // Trigger on canPlay (ready OR streaming) rather than streaming alone —
    // waiting specifically for "streaming" required one extra poll tick
    // after the stream URL was already usable.
    if (state.canPlay && state.streamUrl != null && !_navigating) {
      _navigating = true;
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, animation, __) => TorrentPlayerScreen(
              streamUrl: _engine.streamUrl!,
              title: widget.movieTitle,
              quality: widget.quality,
              engine: _engine,
            ),
            transitionsBuilder: (_, animation, __, child) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            transitionDuration: const Duration(milliseconds: 500),
          ),
        );
      });
    }
  }

  Future<void> _onBack() async {
    await _engine.stop();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _onRetry() async {
    setState(() {
      _state = const TorrentState(phase: TorrentPhase.idle);
      _navigating = false;
    });
    await _engine.start(widget.magnetLink);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) await _engine.stop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF050508),
        body: SafeArea(
          child: Column(
            children: [
              // ── Top bar ────────────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: _onBack,
                    ),
                    const Spacer(),
                    // Phase chip
                    _PhaseChip(phase: _state.phase),
                    const SizedBox(width: 8),
                  ],
                ),
              ),

              const Spacer(),

              // ── Pulsing logo ───────────────────────────────────────────
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => Transform.scale(
                  scale: 0.92 + (_pulse.value * 0.08),
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFCC00), Color(0xFFFF9500)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFFCC00).withValues(
                              alpha: 0.15 + (_pulse.value * 0.35)),
                          blurRadius: 48,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('IF',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1)),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Movie title ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  widget.movieTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              const SizedBox(height: 10),
              _QualityBadge(quality: widget.quality),
              const SizedBox(height: 36),

              // ── Progress indicator ─────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _buildProgress(),
              ),

              const SizedBox(height: 14),

              // ── Status message ─────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _state.displayMessage,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),

              const SizedBox(height: 24),

              // ── Error card ─────────────────────────────────────────────
              if (_state.phase == TorrentPhase.error)
                _ErrorCard(
                  message: _state.errorMessage,
                  onRetry: _onRetry,
                  onBack: _onBack,
                ),

              // ── Stats row (peers, speed) ────────────────────────────────
              if (_state.phase == TorrentPhase.buffering ||
                  _state.phase == TorrentPhase.resolving)
                _StatsRow(state: _state),

              const Spacer(),

              // ── Debug card (collapsible) ───────────────────────────────
              _DebugCard(
                expanded: _debugExpanded,
                onToggle: () =>
                    setState(() => _debugExpanded = !_debugExpanded),
                state: _state,
                magnetLink: widget.magnetLink,
                note: widget.debugNote,
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    if (_state.phase == TorrentPhase.buffering && _state.bufferPct > 0) {
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _state.bufferPct,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor:
                  const AlwaysStoppedAnimation(Color(0xFFFFCC00)),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 13),
              children: [
                TextSpan(
                  text: '${(_state.bufferPct * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: Color(0xFFFFCC00),
                      fontWeight: FontWeight.w800),
                ),
                const TextSpan(
                    text: ' buffered • ',
                    style: TextStyle(color: Colors.white38)),
                TextSpan(
                  text: '${_state.bufferSeconds.toStringAsFixed(0)}s ahead',
                  style: const TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Indeterminate spinner for resolving / ready
    return SizedBox(
      width: 48,
      height: 48,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation(
          _state.phase == TorrentPhase.error
              ? Colors.redAccent
              : const Color(0xFFFFCC00),
        ),
      ),
    );
  }
}

// ── Sub widgets ───────────────────────────────────────────────────────────────

class _PhaseChip extends StatelessWidget {
  final TorrentPhase phase;
  const _PhaseChip({required this.phase});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      TorrentPhase.idle      => ('IDLE', Colors.white24),
      TorrentPhase.resolving => ('RESOLVING', const Color(0xFFFFCC00)),
      TorrentPhase.buffering => ('BUFFERING', const Color(0xFFFFCC00)),
      TorrentPhase.ready     => ('READY', const Color(0xFF22c55e)),
      TorrentPhase.streaming => ('STREAMING', const Color(0xFF22c55e)),
      TorrentPhase.error     => ('ERROR', Colors.redAccent),
    };
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2)),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    final color = quality.contains('1080')
        ? const Color(0xFF3b82f6)
        : quality.contains('4K') || quality.contains('HDR')
            ? const Color(0xFFa855f7)
            : const Color(0xFF22c55e);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(quality,
          style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 13)),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final TorrentState state;
  const _StatsRow({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Stat(
              icon: Icons.people_rounded,
              label: '${state.peers} peers'),
          const SizedBox(width: 20),
          _Stat(
              icon: Icons.download_rounded,
              label:
                  '${state.downloadSpeedMbs.toStringAsFixed(1)} MB/s'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Stat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white30, size: 14),
        const SizedBox(width: 5),
        Text(label,
            style:
                const TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  const _ErrorCard(
      {this.message, required this.onRetry, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: Colors.redAccent.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline,
                color: Colors.redAccent, size: 32),
            const SizedBox(height: 8),
            if (message != null)
              Text(message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: onBack,
                  child: const Text('Go Back',
                      style: TextStyle(color: Colors.white38)),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFCC00),
                      foregroundColor: Colors.black),
                  onPressed: onRetry,
                  child: const Text('Retry',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugCard extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final TorrentState state;
  final String magnetLink;
  final String? note;

  const _DebugCard({
    required this.expanded,
    required this.onToggle,
    required this.state,
    required this.magnetLink,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            // Header tap to expand
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.bug_report_rounded,
                        color: Colors.white24, size: 15),
                    const SizedBox(width: 8),
                    const Text('Debug Info',
                        style: TextStyle(
                            color: Colors.white30, fontSize: 12)),
                    const Spacer(),
                    Icon(
                      expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: Colors.white24,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),

            // Expanded content
            if (expanded) ...[
              const Divider(color: Colors.white10, height: 1),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (note != null) ...[
                      _DebugRow('Note', note!,
                          color: const Color(0xFFFFCC00)),
                      const SizedBox(height: 6),
                    ],
                    _DebugRow('Phase', state.phase.name),
                    _DebugRow('Peers', '${state.peers}'),
                    _DebugRow('Speed',
                        '${state.downloadSpeedMbs.toStringAsFixed(2)} MB/s'),
                    _DebugRow('Buffer',
                        '${(state.bufferPct * 100).toStringAsFixed(0)}% (${state.bufferSeconds.toStringAsFixed(1)}s)'),
                    _DebugRow('Stream URL',
                        state.streamUrl != null
                            ? (state.streamUrl!.length > 50
                                ? '...${state.streamUrl!.substring(state.streamUrl!.length - 50)}'
                                : state.streamUrl!)
                            : '—',
                        copyValue: state.streamUrl), // full URL, untruncated
                    const SizedBox(height: 6),
                    _DebugRow(
                      'Magnet',
                      magnetLink.length > 60
                          ? '${magnetLink.substring(0, 60)}...'
                          : magnetLink,
                      copyValue: magnetLink, // full magnet, untruncated
                    ),
                    if (state.errorMessage != null)
                      _DebugRow('Error', state.errorMessage!,
                          color: Colors.redAccent),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DebugRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  /// When set, shows a copy button that copies THIS full string —
  /// separate from [value], which may be truncated for display.
  final String? copyValue;

  const _DebugRow(this.label, this.value, {this.color, this.copyValue});

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: copyValue!));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1a1a1a),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canCopy = copyValue != null && copyValue!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white24, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: color ?? Colors.white54,
                    fontSize: 11,
                    fontFamily: 'monospace')),
          ),
          if (canCopy)
            GestureDetector(
              onTap: () => _copy(context),
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.copy_rounded,
                    size: 13, color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }
}
