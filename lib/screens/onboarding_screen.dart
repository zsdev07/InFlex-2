import 'package:flutter/material.dart';
import '../services/app_settings.dart';
import '../services/onboarding_catalog.dart';
import 'home_screen.dart';

const Color _gold = Color(0xFFFFCC00);
const Color _bg = Color(0xFF050508);

// ── OnboardingScreen ─────────────────────────────────────────────────────────
//
// Shown once, on the very first launch (splash_screen.dart checks
// AppSettings.onboardingComplete). Three pages:
//   1. Language        - single choice, sets the "For You" row's language.
//   2. Taste tags       - exactly kOnboardingTagCount genres, feeds the same
//                         "For You" row (TmdbService.getForYou).
//   3. Default quality  - the source picker will sort/badge this quality
//                         first (see stream_bottom_sheet.dart).
//
// PopScope blocks the Android back button from leaving the flow early - the
// only way out is finishing page 3. Going back a PAGE (the in-app arrow) is
// still allowed. Everything is written to AppSettings in one call at the end.

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  String? _language;
  final Set<int> _tagIds = {};
  String? _quality;

  bool get _canAdvance => switch (_page) {
        0 => _language != null,
        1 => _tagIds.length == kOnboardingTagCount,
        2 => _quality != null,
        _ => false,
      };

  void _next() {
    if (!_canAdvance) return;
    if (_page == 2) {
      _finish();
      return;
    }
    _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  void _back() {
    if (_page == 0) return;
    _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  Future<void> _finish() async {
    await AppSettings.completeOnboarding(
      language: _language!,
      tagIds: _tagIds.toList(),
      quality: _quality!,
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionDuration: const Duration(milliseconds: 400),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),
              _StepDots(current: _page, count: 3),
              const SizedBox(height: 8),
              if (_page > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white70),
                    onPressed: _back,
                  ),
                ),
              Expanded(
                child: PageView(
                  controller: _pageCtrl,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    _LanguagePage(
                      selected: _language,
                      onSelect: (c) => setState(() => _language = c),
                    ),
                    _TagsPage(
                      selected: _tagIds,
                      onToggle: (id) => setState(() {
                        if (_tagIds.contains(id)) {
                          _tagIds.remove(id);
                        } else if (_tagIds.length < kOnboardingTagCount) {
                          _tagIds.add(id);
                        }
                      }),
                    ),
                    _QualityPage(
                      selected: _quality,
                      onSelect: (q) => setState(() => _quality = q),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _canAdvance ? _next : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white12,
                      disabledForegroundColor: Colors.white30,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      _page == 2 ? 'Get Started' : 'Continue',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  final int current;
  final int count;
  const _StepDots({required this.current, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == current;
        final done = i < current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active || done ? _gold : Colors.white12,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _PageHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
}

// ── Page 1: language ──────────────────────────────────────────────────────────

class _LanguagePage extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;
  const _LanguagePage({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(
          title: 'What do you want to watch in?',
          subtitle:
              "We'll suggest movies in this language first - you can still "
              'watch anything, this just picks your starting point.',
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            itemCount: kOnboardingLanguages.length,
            itemBuilder: (_, i) {
              final lang = kOnboardingLanguages[i];
              final active = selected == lang.code;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ChoiceTile(
                  label: lang.name,
                  selected: active,
                  onTap: () => onSelect(lang.code),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _gold.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _gold : Colors.white.withValues(alpha: 0.06),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: selected ? _gold : Colors.white,
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w500)),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded, color: _gold, size: 20)
              else
                const Icon(Icons.circle_outlined,
                    color: Colors.white24, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Page 2: tags ──────────────────────────────────────────────────────────────

class _TagsPage extends StatelessWidget {
  final Set<int> selected;
  final ValueChanged<int> onToggle;
  const _TagsPage({required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PageHeader(
          title: 'Pick $kOnboardingTagCount things you love',
          subtitle: selected.length == kOnboardingTagCount
              ? "Perfect - that's your $kOnboardingTagCount."
              : 'Chosen ${selected.length} of $kOnboardingTagCount. We use '
                  'these to build your "Recommended for you" row.',
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final tag in kOnboardingTags)
                  _TagChip(
                    label: tag.name,
                    selected: selected.contains(tag.genreId),
                    disabled: !selected.contains(tag.genreId) &&
                        selected.length >= kOnboardingTagCount,
                    onTap: () => onToggle(tag.genreId),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;
  const _TagChip({
    required this.label,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? _gold : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? _gold
                : Colors.white.withValues(alpha: disabled ? 0.03 : 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? Colors.black
                : (disabled ? Colors.white24 : Colors.white70),
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Page 3: quality ───────────────────────────────────────────────────────────

class _QualityPage extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;
  const _QualityPage({required this.selected, required this.onSelect});

  static const Map<String, String> _hints = {
    '4K': 'Best picture - needs the strongest connection and swarm.',
    '1080p': 'Full HD - the usual sweet spot.',
    '720p': 'HD - loads faster on a weaker connection.',
    '480p': 'Standard - smallest downloads, most reliable start.',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(
          title: 'Default quality',
          subtitle:
              "We'll show this quality first when you pick a source - you "
              'can always choose another one per movie.',
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            itemCount: kOnboardingQualities.length,
            itemBuilder: (_, i) {
              final q = kOnboardingQualities[i];
              final active = selected == q;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: active
                      ? _gold.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onSelect(q),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: active
                              ? _gold
                              : Colors.white.withValues(alpha: 0.06),
                          width: active ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(q,
                                    style: TextStyle(
                                        color: active ? _gold : Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800)),
                                const SizedBox(height: 3),
                                Text(_hints[q] ?? '',
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 11)),
                              ],
                            ),
                          ),
                          if (active)
                            const Icon(Icons.check_circle_rounded,
                                color: _gold, size: 20)
                          else
                            const Icon(Icons.circle_outlined,
                                color: Colors.white24, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
