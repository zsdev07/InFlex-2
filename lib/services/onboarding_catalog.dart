// ── OnboardingCatalog ────────────────────────────────────────────────────────
//
// The fixed lists the onboarding flow (screens/onboarding_screen.dart) shows,
// and the TMDB codes/ids each option maps to. Kept separate from the screen so
// TmdbService can build "For You" queries from the same data without a UI
// import.

class LanguageOption {
  final String code; // TMDB with_original_language
  final String name;
  const LanguageOption(this.code, this.name);
}

const List<LanguageOption> kOnboardingLanguages = [
  LanguageOption('hi', 'Hindi'),
  LanguageOption('en', 'English'),
  LanguageOption('ta', 'Tamil'),
  LanguageOption('te', 'Telugu'),
  LanguageOption('ml', 'Malayalam'),
  LanguageOption('kn', 'Kannada'),
  LanguageOption('bn', 'Bengali'),
  LanguageOption('mr', 'Marathi'),
  LanguageOption('pa', 'Punjabi'),
  LanguageOption('gu', 'Gujarati'),
  LanguageOption('ko', 'Korean'),
  LanguageOption('ja', 'Japanese'),
  LanguageOption('es', 'Spanish'),
  LanguageOption('fr', 'French'),
];

class TagOption {
  final String name;
  final int genreId; // TMDB genre id
  const TagOption(this.name, this.genreId);
}

/// Exactly the number of tags the onboarding flow asks the person to pick.
const int kOnboardingTagCount = 3;

const List<TagOption> kOnboardingTags = [
  TagOption('Action', 28),
  TagOption('Comedy', 35),
  TagOption('Thriller', 53),
  TagOption('Romance', 10749),
  TagOption('Horror', 27),
  TagOption('Sci-Fi', 878),
  TagOption('Drama', 18),
  TagOption('Animation', 16),
  TagOption('Crime', 80),
  TagOption('Fantasy', 14),
  TagOption('Adventure', 12),
  TagOption('Mystery', 9648),
  TagOption('Family', 10751),
  TagOption('War', 10752),
  TagOption('Musical', 10402),
  TagOption('Documentary', 99),
];

/// Playback quality choices, in the same words the source picker shows
/// (services/release_parser.dart's ReleaseInfo.resolution).
const List<String> kOnboardingQualities = ['4K', '1080p', '720p', '480p'];
