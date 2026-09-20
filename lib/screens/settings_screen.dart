import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/app_settings.dart';
import 'watchlist_screen.dart';

// ── SettingsScreen ────────────────────────────────────────────────────────────
//
// Replaces the old Watchlist tab in the home screen's bottom bar. The
// watchlist itself lives on as a sub-page of Settings ("Library"), and this
// is where future options go (download mode, preferred language, ...).
//
// Everything here is persisted through AppSettings (Hive box 'settings').

const Color _accent = Color(0xFFFFCC00);

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const _SectionTitle('LIBRARY'),
        _NavTile(
          icon: Icons.bookmark_rounded,
          title: 'Watchlist',
          subtitle: 'Titles you saved for later',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const _WatchlistPage()),
          ),
        ),
        const SizedBox(height: 24),
        const _SectionTitle('PLAYBACK  ·  EXPERIMENTAL'),
        const _SmartPreBufferTile(),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Experimental options are still being tuned and may change or '
            'be removed in a later version.',
            style: TextStyle(color: Colors.white24, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _WatchlistPage extends StatelessWidget {
  const _WatchlistPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      appBar: AppBar(
        backgroundColor: const Color(0xFF050508),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Watchlist',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: const WatchlistScreen(),
    );
  }
}

// ── Smart pre-buffer ──────────────────────────────────────────────────────────

class _SmartPreBufferTile extends StatelessWidget {
  const _SmartPreBufferTile();

  static const String _title = 'Smart pre-buffer';
  static const String _description =
      'Waits until the start of the movie is fully buffered before playing, '
      'instead of using a fixed timer. It only gives up when a source stops '
      'loading - then you can keep waiting, play anyway, or pick another '
      'source. Smoother on weak sources, but starting can take longer.';

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen(AppSettings.boxName)) {
      return const _SwitchTile(
        icon: Icons.hourglass_top_rounded,
        title: _title,
        description: _description,
        value: false,
        onChanged: null,
      );
    }
    return ValueListenableBuilder<Box<dynamic>>(
      valueListenable: Hive.box<dynamic>(AppSettings.boxName)
          .listenable(keys: [AppSettings.keySmartPreBuffer]),
      builder: (context, box, _) => _SwitchTile(
        icon: Icons.hourglass_top_rounded,
        title: _title,
        description: _description,
        value: AppSettings.smartPreBuffer,
        onChanged: (v) => AppSettings.setSmartPreBuffer(v),
      ),
    );
  }
}

// ── Building blocks ───────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: _accent,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _IconBox(icon: icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value
              ? _accent.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBox(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('EXPERIMENTAL',
                          style: TextStyle(
                              color: _accent,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(description,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.black
                  : Colors.white54,
            ),
            trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? _accent
                  : Colors.white12,
            ),
            trackOutlineColor:
                const WidgetStatePropertyAll<Color>(Colors.transparent),
          ),
        ],
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  const _IconBox({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: _accent, size: 20),
    );
  }
}
