import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class PlayerScreen extends StatefulWidget {
  final String streamUrl;
  final String title;
  final String? subtitle;
  final bool isEmbed;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.title,
    this.subtitle,
    this.isEmbed = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Video player
  VideoPlayerController? _vpc;
  ChewieController? _cc;
  bool _initialized = false;
  String? _error;

  // WebView controller for embed sources
  WebViewController? _webCtrl;

  // Overlay
  bool _showOverlay = true;
  bool _locked = false;
  double _brightness = 1.0;
  double _volume = 1.0;
  double _playbackSpeed = 1.0;
  String _quality = '1080p';
  String _audio = 'Hindi';
  String _subtitle = 'Off';
  String? _activeMenu;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (widget.isEmbed) {
      _initWebView();
    } else {
      _initPlayer();
    }
    _startHideTimer();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _vpc?.dispose();
    _cc?.dispose();
    super.dispose();
  }

  void _initWebView() {
    _webCtrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          setState(() => _initialized = true);
          // Inject CSS to make video fullscreen
          _webCtrl?.runJavaScript('''
            document.body.style.margin = '0';
            document.body.style.padding = '0';
            document.body.style.background = 'black';
            var videos = document.querySelectorAll('video');
            videos.forEach(function(v) {
              v.style.width = '100%';
              v.style.height = '100%';
            });
          ''');
        },
        onWebResourceError: (error) {
          setState(() => _error = 'Could not load stream: ${error.description}');
        },
      ))
      ..loadRequest(Uri.parse(widget.streamUrl));
    setState(() {});
  }

  Future<void> _initPlayer() async {
    try {
      _vpc = VideoPlayerController.networkUrl(
        Uri.parse(widget.streamUrl),
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36',
          'Referer': 'https://torrentio.strem.fun/',
        },
      );
      await _vpc!.initialize();
      _cc = ChewieController(
        videoPlayerController: _vpc!,
        autoPlay: true,
        looping: false,
        showControls: false,
        aspectRatio: _vpc!.value.aspectRatio,
        allowFullScreen: false,
        allowMuting: true,
      );
      setState(() => _initialized = true);
    } catch (e) {
      setState(() => _error = 'Could not load stream.\n$e');
    }
  }

  void _startHideTimer() {
    Future.delayed(const Duration(seconds: 4), () {
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
    setState(() => _activeMenu = null);
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
    if (_vpc == null) return;
    _vpc!.value.isPlaying ? _vpc!.pause() : _vpc!.play();
    setState(() {});
  }

  void _seek(int seconds) {
    if (_vpc == null) return;
    final pos = _vpc!.value.position;
    final dur = _vpc!.value.duration;
    final newPos = pos + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : newPos > dur
            ? dur
            : newPos;
    _vpc!.seekTo(clamped);
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: widget.isEmbed ? _buildWebView() : _buildVideoPlayer(),
    );
  }

  // ── WEBVIEW PLAYER (for embed sources) ───────────────────────────────────
  Widget _buildWebView() {
    return Stack(
      children: [
        if (_webCtrl != null)
          WebViewWidget(controller: _webCtrl!)
        else
          const Center(child: CircularProgressIndicator(color: Color(0xFFFFCC00))),

        if (!_initialized)
          const Center(child: CircularProgressIndicator(color: Color(0xFFFFCC00))),

        if (_error != null)
          Center(child: _buildError()),

        // Back button always visible for webview
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: AnimatedOpacity(
              opacity: _showOverlay ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                      ),
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
                          Text(
                            widget.title + (widget.subtitle != null ? ' • ${widget.subtitle}' : ''),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Tap to show/hide overlay
        GestureDetector(
          onTapDown: (_) => setState(() => _showOverlay = !_showOverlay),
          child: Container(color: Colors.transparent),
        ),
      ],
    );
  }

  // ── VIDEO PLAYER (for torrent streams) ───────────────────────────────────
  Widget _buildVideoPlayer() {
    return GestureDetector(
      onTapDown: _handleTap,
      child: Stack(
        children: [
          if (_initialized && _cc != null)
            Center(
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix([
                  _brightness, 0, 0, 0, 0,
                  0, _brightness, 0, 0, 0,
                  0, 0, _brightness, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
                child: Chewie(controller: _cc!),
              ),
            )
          else if (_error != null)
            Center(child: _buildError())
          else
            const Center(
              child: CircularProgressIndicator(
                  color: Color(0xFFFFCC00), strokeWidth: 2.5),
            ),

          if (_initialized) _buildOverlay(),
        ],
      ),
    );
  }

  Widget _buildError() {
  final isCodec = _error != null &&
      (_error!.contains('EXCEEDS_CAPABILITIES') ||
       _error!.contains('hevc') ||
       _error!.contains('hvc') ||
       _error!.contains('VideoError'));

  return Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
        const SizedBox(height: 12),
        Text(
          isCodec
              ? 'This video uses HEVC/H.265 which your device cannot decode.'
              : _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
        const SizedBox(height: 20),

        // Open in external player button (only shown on codec errors)
        if (isCodec) ...[
          ElevatedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open in External Player',
                style: TextStyle(fontWeight: FontWeight.w800)),
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
        ],

        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Go Back',
              style: TextStyle(
                  color: Colors.white54, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  }

  Widget _buildOverlay() {
    final vpc = _vpc!;
    final pos = vpc.value.position;
    final dur = vpc.value.duration;
    final prog = dur.inMilliseconds > 0
        ? pos.inMilliseconds / dur.inMilliseconds
        : 0.0;

    return AnimatedOpacity(
      opacity: _showOverlay ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Stack(
        children: [
          // Top gradient
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 120,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),
          // Bottom gradient
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              height: 160,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),

          // Top bar
          if (!_locked)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                        ),
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
                            Text(
                              widget.title + (widget.subtitle != null ? ' • ${widget.subtitle}' : ''),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Brightness slider left
          if (!_locked)
            Positioned(
              left: 12, top: 0, bottom: 0,
              child: Center(child: _VerticalSlider(
                value: _brightness, min: 0.2, max: 1.8,
                icon: Icons.wb_sunny_rounded,
                onChanged: (v) => setState(() => _brightness = v),
              )),
            ),

          // Volume slider right
          if (!_locked)
            Positioned(
              right: 12, top: 0, bottom: 0,
              child: Center(child: _VerticalSlider(
                value: _volume, min: 0.0, max: 1.0,
                icon: Icons.volume_up_rounded,
                onChanged: (v) {
                  setState(() => _volume = v);
                  vpc.setVolume(v);
                },
              )),
            ),

          // Center controls
          if (!_locked)
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _SeekButton(icon: Icons.replay_10, onTap: () { _seek(-15); _resetTimer(); }, label: '15', reverse: true),
                  const SizedBox(width: 32),
                  GestureDetector(
                    onTap: () { _togglePlay(); _resetTimer(); },
                    child: _PlayButton(playing: vpc.value.isPlaying, progress: prog),
                  ),
                  const SizedBox(width: 32),
                  _SeekButton(icon: Icons.forward_10, onTap: () { _seek(15); _resetTimer(); }, label: '15', reverse: false),
                ],
              ),
            ),

          // Lock screen
          if (_locked && _showOverlay)
            Center(
              child: GestureDetector(
                onTap: () => setState(() { _locked = false; _showOverlay = true; _resetTimer(); }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFCC00).withValues(alpha: 0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_open_rounded, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('Unlock Screen', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom controls
          if (!_locked)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      // Progress
                      Row(
                        children: [
                          Text(_formatDuration(pos),
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: const Color(0xFFFFCC00),
                                inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                                thumbColor: Colors.white,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                overlayShape: SliderComponentShape.noOverlay,
                                trackHeight: 3,
                              ),
                              child: Slider(
                                value: prog.clamp(0.0, 1.0),
                                onChanged: (v) {
                                  _resetTimer();
                                  vpc.seekTo(Duration(milliseconds: (v * dur.inMilliseconds).toInt()));
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(_formatDuration(dur),
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      // Action buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _ActionBtn(icon: Icons.lock_rounded, label: 'Lock',
                              onTap: () => setState(() { _locked = true; _showOverlay = false; })),
                          _MenuBtn(
                            label: '${_playbackSpeed}x', icon: Icons.speed_rounded,
                            active: _activeMenu == 'speed',
                            onTap: () => setState(() => _activeMenu = _activeMenu == 'speed' ? null : 'speed'),
                            menu: _activeMenu == 'speed' ? _PopupMenu(
                              items: const ['0.5x', '0.75x', '1.0x', '1.25x', '1.5x', '2.0x'],
                              active: '${_playbackSpeed}x',
                              onSelect: (v) {
                                final spd = double.parse(v.replaceAll('x', ''));
                                setState(() { _playbackSpeed = spd; _activeMenu = null; });
                                vpc.setPlaybackSpeed(spd);
                              },
                            ) : null,
                          ),
                          _MenuBtn(
                            label: _quality, icon: Icons.hd_rounded,
                            active: _activeMenu == 'quality',
                            onTap: () => setState(() => _activeMenu = _activeMenu == 'quality' ? null : 'quality'),
                            menu: _activeMenu == 'quality' ? _PopupMenu(
                              items: const ['4K HDR', '1080p', '720p', '480p'],
                              active: _quality,
                              onSelect: (v) => setState(() { _quality = v; _activeMenu = null; }),
                            ) : null,
                          ),
                          _MenuBtn(
                            label: _audio, icon: Icons.music_note_rounded,
                            active: _activeMenu == 'audio',
                            onTap: () => setState(() => _activeMenu = _activeMenu == 'audio' ? null : 'audio'),
                            menu: _activeMenu == 'audio' ? _PopupMenu(
                              items: const ['Hindi', 'English', 'Tamil', 'Telugu'],
                              active: _audio,
                              onSelect: (v) => setState(() { _audio = v; _activeMenu = null; }),
                            ) : null,
                          ),
                          _MenuBtn(
                            label: 'Subs', icon: Icons.subtitles_rounded,
                            active: _activeMenu == 'sub',
                            onTap: () => setState(() => _activeMenu = _activeMenu == 'sub' ? null : 'sub'),
                            menu: _activeMenu == 'sub' ? _PopupMenu(
                              items: const ['Off', 'Hindi', 'English'],
                              active: _subtitle,
                              onSelect: (v) => setState(() { _subtitle = v; _activeMenu = null; }),
                            ) : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── SUB WIDGETS ───────────────────────────────────────────────────────────────

class _VerticalSlider extends StatelessWidget {
  final double value, min, max;
  final IconData icon;
  final ValueChanged<double> onChanged;
  const _VerticalSlider({required this.value, required this.min, required this.max, required this.icon, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 130,
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFFFFCC00),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: SliderComponentShape.noOverlay,
                trackHeight: 4,
              ),
              child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
            ),
          ),
        ),
        Icon(icon, color: Colors.white54, size: 18),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final double progress;
  const _PlayButton({required this.playing, required this.progress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76, height: 76,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress, strokeWidth: 3,
            backgroundColor: const Color(0xFFFFCC00).withValues(alpha: 0.15),
            valueColor: const AlwaysStoppedAnimation(Color(0xFFFFCC00)),
          ),
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.4), shape: BoxShape.circle),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: const Color(0xFFFFCC00), size: 32,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final bool reverse;
  const _SeekButton({required this.icon, required this.onTap, required this.label, required this.reverse});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.1),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white60, size: 20),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _MenuBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final Widget? menu;
  const _MenuBtn({required this.label, required this.icon, required this.active, required this.onTap, this.menu});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (menu != null) Positioned(bottom: 52, left: -40, child: menu!),
        GestureDetector(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: active ? const Color(0xFFFFCC00) : Colors.white60, size: 20),
              const SizedBox(height: 3),
              Text(label, style: TextStyle(
                  color: active ? const Color(0xFFFFCC00) : Colors.white38,
                  fontSize: 10, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PopupMenu extends StatelessWidget {
  final List<String> items;
  final String active;
  final ValueChanged<String> onSelect;
  const _PopupMenu({required this.items, required this.active, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E16).withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFCC00).withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: items.map((item) {
          final sel = item == active;
          return GestureDetector(
            onTap: () => onSelect(item),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: sel ? const Color(0xFFFFCC00).withValues(alpha: 0.1) : Colors.transparent,
              child: Text(item,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: sel ? const Color(0xFFFFCC00) : Colors.white70,
                      fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                      fontSize: 13)),
            ),
          );
        }).toList(),
      ),
    );
  }
}
