import 'dart:async';
import 'package:flutter/material.dart';
import '../services/debrid_service.dart';
import '../services/stream_service.dart';
import 'player_screen.dart';

/// ── DebridResolverScreen ───────────────────────────────────────────────────
///
/// Orchestrates the full "Check Cache → Leech if missing → Stream" flow.
///
/// Entry points:
///   • Navigator.push(DebridResolverScreen(...))  — from StreamBottomSheet
///
/// The screen:
///   1. checkCache(imdbId)
///   2a. Hit  → show "Instant Play" badge, push PlayerScreen after 600ms
///   2b. Miss → leech(magnetLink) → poll every 5s → push PlayerScreen on ready

class DebridResolverScreen extends StatefulWidget {
  final String imdbId;
  final String magnetLink;
  final String movieTitle;
  final String quality;

  /// Passed through to PlayerScreen for the title bar.
  final String? subtitle;

  const DebridResolverScreen({
    super.key,
    required this.imdbId,
    required this.magnetLink,
    required this.movieTitle,
    required this.quality,
    this.subtitle,
  });

  @override
  State<DebridResolverScreen> createState() => _DebridResolverScreenState();
}

class _DebridResolverScreenState extends State<DebridResolverScreen>
    with SingleTickerProviderStateMixin {
  DebridStatus _status = DebridStatus.queued;
  int _progress = 0;
  double _downloadedMb = 0;
  double _totalMb = 0;
  String _message = 'Checking InFlex cache...';
  bool _cached = false;

  Timer? _pollTimer;
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  // ── ENTRY POINT ────────────────────────────────────────────────────────────

  Future<void> _start() async {
    // Step 1: cache check
    final cached = await DebridService.checkCache(widget.imdbId,
        quality: widget.quality);

    if (!mounted) return;

    if (cached.isCached && cached.streamUrl != null) {
      _handleReady(cached, fromCache: true);
      return;
    }

    // Step 2: not cached — kick off leech
    _setStatus(DebridStatus.queued, message: 'Starting leech...');
    final accepted = await DebridService.leech(
      magnetLink: widget.magnetLink,
      imdbId: widget.imdbId,
      quality: widget.quality,
      title: widget.movieTitle,
    );

    if (!mounted) return;

    if (!accepted) {
      _setStatus(DebridStatus.error,
          message: 'Debrid bot unavailable. Try another source.');
      return;
    }

    // Step 3: poll until ready
    _pollTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll(); // first poll immediately
  }

  Future<void> _poll() async {
    final result = await DebridService.pollStatus(widget.imdbId,
        quality: widget.quality);

    if (!mounted) return;

    if (result.isCached && result.streamUrl != null) {
      _pollTimer?.cancel();
      _handleReady(result, fromCache: false);
      return;
    }

    _setStatusFromResult(result);
  }

  // ── STATE HELPERS ──────────────────────────────────────────────────────────

  void _setStatus(DebridStatus s, {String? message}) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _message = message ?? s.name;
    });
  }

  void _setStatusFromResult(DebridResult r) {
    if (!mounted) return;
    setState(() {
      _status = r.status;
      _progress = r.progressPercent;
      _downloadedMb = r.downloadedMb;
      _totalMb = r.totalMb;
      _message = r.displayMessage;
    });
  }

  Future<void> _handleReady(DebridResult result, {required bool fromCache}) async {
    setState(() {
      _status = DebridStatus.cached;
      _cached = fromCache;
      _message = fromCache
          ? 'Already on Telegram — instant play!'
          : 'Upload complete — starting playback...';
    });

    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          streamUrl: result.streamUrl!,
          title: widget.movieTitle,
          subtitle: widget.subtitle,
          isEmbed: false,
        ),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      body: SafeArea(
        child: Column(
          children: [
            // Back button
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  _pollTimer?.cancel();
                  Navigator.pop(context);
                },
              ),
            ),

            const Spacer(),

            // Pulsing logo
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Transform.scale(
                scale: 0.92 + (_pulse.value * 0.08),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFCC00), Color(0xFFFFD740)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFFCC00)
                            .withValues(alpha: 0.2 + (_pulse.value * 0.4)),
                        blurRadius: 40,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text(
                      'IF',
                      style: TextStyle(
                          color: Colors.black,
                          fontSize: 38,
                          fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                widget.movieTitle,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            const SizedBox(height: 10),
            _QualityBadge(quality: widget.quality),
            const SizedBox(height: 36),

            // Progress area
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: _buildProgress(),
            ),

            const SizedBox(height: 16),

            // Status message
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _message,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 16),

            if (_cached) _CacheBadge(),

            const SizedBox(height: 24),

            if (_status == DebridStatus.downloading ||
                _status == DebridStatus.uploading ||
                _status == DebridStatus.queued)
              _InfoCard(downloadedMb: _downloadedMb, totalMb: _totalMb),

            if (_status == DebridStatus.error) _ErrorCard(onBack: () {
              _pollTimer?.cancel();
              Navigator.pop(context);
            }),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    if ((_status == DebridStatus.downloading ||
            _status == DebridStatus.uploading) &&
        _progress > 0) {
      final color = _status == DebridStatus.uploading
          ? const Color(0xFF22c55e)
          : const Color(0xFFFFCC00);
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress / 100,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '$_progress%',
            style: TextStyle(
                color: color, fontSize: 32, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            _status == DebridStatus.uploading
                ? 'Uploading to Telegram'
                : 'Downloading torrent',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      );
    }

    // Spinner
    return SizedBox(
      width: 52,
      height: 52,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation(
          _status == DebridStatus.cached
              ? const Color(0xFF22c55e)
              : const Color(0xFFFFCC00),
        ),
      ),
    );
  }
}

// ── SUB WIDGETS ───────────────────────────────────────────────────────────────

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    final color = quality.contains('1080')
        ? const Color(0xFF3b82f6)
        : const Color(0xFF22c55e);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(quality,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 13)),
    );
  }
}

class _CacheBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF22c55e).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFF22c55e).withValues(alpha: 0.3)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, color: Color(0xFF22c55e), size: 18),
          SizedBox(width: 6),
          Text('Instant play — already cached!',
              style: TextStyle(
                  color: Color(0xFF22c55e),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final double downloadedMb;
  final double totalMb;
  const _InfoCard({required this.downloadedMb, required this.totalMb});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            if (downloadedMb > 0 && totalMb > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Downloaded',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                  Text(
                    '${downloadedMb.toStringAsFixed(0)} / ${totalMb.toStringAsFixed(0)} MB',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            if (downloadedMb > 0) const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.white24, size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Leeched once. All future plays are instant from Telegram.',
                    style: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final VoidCallback onBack;
  const _ErrorCard({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
          const SizedBox(height: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFCC00),
                foregroundColor: Colors.black),
            onPressed: onBack,
            child: const Text('Go Back',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
