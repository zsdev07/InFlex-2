import 'dart:async';
import 'package:flutter/material.dart';
import '../services/inflex_resolver_service.dart';
import 'player_screen.dart';

class ResolverScreen extends StatefulWidget {
  final String infoHash;
  final int fileIdx;
  final String movieTitle;
  final String quality;
  final String imdbId;

  const ResolverScreen({
    super.key,
    required this.infoHash,
    required this.fileIdx,
    required this.movieTitle,
    required this.quality,
    required this.imdbId,
  });

  @override
  State<ResolverScreen> createState() => _ResolverScreenState();
}

class _ResolverScreenState extends State<ResolverScreen>
    with SingleTickerProviderStateMixin {
  ResolveStatus _status = ResolveStatus.queued;
  int _progress = 0;
  double _downloadedMb = 0;
  double _totalMb = 0;
  String _message = 'Connecting to InFlex servers...';
  bool _cached = false;
  Timer? _timer;
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    final result = await InFlexResolverService.resolve(
      infoHash: widget.infoHash,
      fileIdx: widget.fileIdx,
      title: widget.imdbId,
    );

    if (!mounted) return;

    setState(() {
      _status = result.status;
      _progress = result.progress;
      _downloadedMb = result.downloadedMb;
      _totalMb = result.totalMb;
      _message = result.message ?? _defaultMessage(result.status);
      _cached = result.cached;
    });

    if (result.status == ResolveStatus.ready && result.streamUrl != null) {
      _timer?.cancel();
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            streamUrl: result.streamUrl!,
            title: widget.movieTitle,
            isEmbed: false,
          ),
        ),
      );
    }
  }

  String _defaultMessage(ResolveStatus s) {
    switch (s) {
      case ResolveStatus.queued:      return 'Queued — starting download...';
      case ResolveStatus.downloading: return 'Downloading to InFlex servers...';
      case ResolveStatus.ready:       return 'Ready! Starting playback...';
      case ResolveStatus.error:       return 'Something went wrong. Go back and try another source.';
    }
  }

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
                onPressed: () { _timer?.cancel(); Navigator.pop(context); },
              ),
            ),

            const Spacer(),

            // Pulsing logo
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Transform.scale(
                scale: 0.92 + (_pulse.value * 0.08),
                child: Container(
                  width: 100, height: 100,
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
                    child: Text('IF',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 38,
                            fontWeight: FontWeight.w900)),
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

            // Quality badge
            _QualityBadge(quality: widget.quality),

            const SizedBox(height: 36),

            // Progress area
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: _buildProgress(),
            ),

            const SizedBox(height: 16),

            // Message
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _message,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 16),

            // Cache badge
            if (_cached) _CacheBadge(),

            const SizedBox(height: 24),

            // Info card
            if (_status == ResolveStatus.downloading ||
                _status == ResolveStatus.queued)
              _InfoCard(downloadedMb: _downloadedMb, totalMb: _totalMb),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    if (_status == ResolveStatus.downloading && _progress > 0) {
      return Column(
        children: [
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress / 100,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation(Color(0xFFFFCC00)),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '$_progress%',
            style: const TextStyle(
                color: Color(0xFFFFCC00),
                fontSize: 32,
                fontWeight: FontWeight.w900),
          ),
        ],
      );
    }

    // Spinner for queued/ready
    return SizedBox(
      width: 52, height: 52,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation(
          _status == ResolveStatus.ready
              ? const Color(0xFF22c55e)
              : const Color(0xFFFFCC00),
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
        border: Border.all(
            color: const Color(0xFF22c55e).withValues(alpha: 0.3)),
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
                    'First request downloads once. Everyone after gets instant play!',
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
