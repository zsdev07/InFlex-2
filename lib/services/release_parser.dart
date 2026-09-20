// ── release_parser.dart ───────────────────────────────────────────────────────
//
// Pure-Dart helpers that turn a torrent release name into things a person can
// read at a glance: resolution, source (BluRay / WEB-DL ...), codec, HDR,
// audio format and - the important one - the AUDIO LANGUAGES.
//
// Torrentio gives us three kinds of clues and we use all of them:
//   1. the release / file name        ("Jawan.2023.Hindi.1080p.WEB-DL...")
//   2. a language line of flag emoji   ("🇬🇧 / 🇮🇳")
//   3. the movie's own TMDB language   (untagged releases are almost always
//      the original audio)
//
// Language detection is a heuristic, so the UI labels it "from title" and
// never claims more than the name says.

/// How healthy a torrent's swarm looks, from the tracker-reported seeders.
/// (Those numbers are scrapes and can be stale - treat as a hint.)
enum SeedHealth { strong, good, weak, veryLow, unknown }

SeedHealth seedHealthFor(int? seeds) {
  if (seeds == null) return SeedHealth.unknown;
  if (seeds >= 500) return SeedHealth.strong;
  if (seeds >= 100) return SeedHealth.good;
  if (seeds >= 20) return SeedHealth.weak;
  return SeedHealth.veryLow;
}

/// TMDB / ISO-639-1 language code -> display name (for "original audio").
String? languageNameForCode(String? code) {
  if (code == null) return null;
  return _codeNames[code.toLowerCase().trim()];
}

const Map<String, String> _codeNames = {
  'en': 'English',
  'hi': 'Hindi',
  'ta': 'Tamil',
  'te': 'Telugu',
  'ml': 'Malayalam',
  'kn': 'Kannada',
  'bn': 'Bengali',
  'mr': 'Marathi',
  'pa': 'Punjabi',
  'gu': 'Gujarati',
  'ur': 'Urdu',
  'ja': 'Japanese',
  'ko': 'Korean',
  'zh': 'Chinese',
  'cn': 'Chinese',
  'fr': 'French',
  'es': 'Spanish',
  'de': 'German',
  'it': 'Italian',
  'ru': 'Russian',
  'pt': 'Portuguese',
  'tr': 'Turkish',
  'ar': 'Arabic',
  'th': 'Thai',
  'nl': 'Dutch',
  'pl': 'Polish',
};

const Map<String, String> _languagePatterns = {
  'Hindi': r'\bhindi\b',
  'Tamil': r'\btamil\b',
  'Telugu': r'\btelugu\b',
  'Malayalam': r'\bmalayalam\b',
  'Kannada': r'\bkannada\b',
  'Bengali': r'\b(?:bengali|bangla)\b',
  'Punjabi': r'\bpunjabi\b',
  'Marathi': r'\bmarathi\b',
  'Gujarati': r'\bgujarati\b',
  'Urdu': r'\burdu\b',
  'English': r'\benglish\b',
  'French': r'\b(?:french|vff|vfq|truefrench)\b',
  'Spanish': r'\b(?:spanish|castellano|latino)\b',
  'German': r'\bgerman\b',
  'Italian': r'\bitalian\b',
  'Russian': r'\brussian\b',
  'Japanese': r'\bjapanese\b',
  'Korean': r'\bkorean\b',
  'Chinese': r'\b(?:chinese|mandarin|cantonese)\b',
  'Portuguese': r'\bportuguese\b',
  'Turkish': r'\bturkish\b',
  'Arabic': r'\barabic\b',
  'Thai': r'\bthai\b',
  'Dutch': r'\bdutch\b',
  'Polish': r'\bpolish\b',
};

/// 3-letter codes are only trusted when several appear together
/// ("Hin-Eng", "Hin+Tam+Tel") - alone they collide with ordinary words.
const Map<String, String> _codeLanguages = {
  'hin': 'Hindi',
  'tam': 'Tamil',
  'tel': 'Telugu',
  'mal': 'Malayalam',
  'kan': 'Kannada',
  'ben': 'Bengali',
  'mar': 'Marathi',
  'pun': 'Punjabi',
  'eng': 'English',
  'kor': 'Korean',
  'jpn': 'Japanese',
  'fre': 'French',
  'ger': 'German',
  'spa': 'Spanish',
  'ita': 'Italian',
  'rus': 'Russian',
  'chi': 'Chinese',
};

/// Country flag (as Torrentio prints it) -> language. 🇮🇳 is deliberately not
/// here: Torrentio uses it for every Indian language, so it only tells us
/// "some Indian language" (see ReleaseInfo.indianFlag).
const Map<String, String> _flagLanguages = {
  'GB': 'English',
  'US': 'English',
  'FR': 'French',
  'ES': 'Spanish',
  'MX': 'Spanish',
  'IT': 'Italian',
  'DE': 'German',
  'RU': 'Russian',
  'JP': 'Japanese',
  'KR': 'Korean',
  'CN': 'Chinese',
  'TW': 'Chinese',
  'PT': 'Portuguese',
  'BR': 'Portuguese',
  'NL': 'Dutch',
  'PL': 'Polish',
  'TR': 'Turkish',
  'TH': 'Thai',
  'SA': 'Arabic',
};

class ReleaseInfo {
  final String? resolution; // 4K / 1080p / 720p / 480p
  final String? source; // BluRay / WEB-DL / WEBRip / Remux ...
  final String? codec; // HEVC / x264 / AV1
  final String? hdr; // HDR / HDR10+ / DV / DV · HDR
  final String? audio; // Atmos / DD+ 5.1 / DTS ...

  /// Audio/dub languages that the release NAME (or flags) actually states.
  final List<String> languages;
  final bool dualAudio;
  final bool multiAudio;
  final bool hasSubs;

  /// Torrentio tagged the release with the 🇮🇳 flag (any Indian language).
  final bool indianFlag;

  const ReleaseInfo({
    this.resolution,
    this.source,
    this.codec,
    this.hdr,
    this.audio,
    this.languages = const [],
    this.dualAudio = false,
    this.multiAudio = false,
    this.hasSubs = false,
    this.indianFlag = false,
  });

  static const ReleaseInfo empty = ReleaseInfo();

  /// True when the name says nothing about language, so we fall back to the
  /// movie's original language.
  bool get languageAssumed => languages.isEmpty;

  /// Languages to show / filter by. Untagged releases count as the movie's
  /// original language (e.g. "Hindi" for a Hindi film).
  List<String> audioLanguages(String? originalLanguageName) {
    if (languages.isNotEmpty) return languages;
    if (originalLanguageName != null) return [originalLanguageName];
    return const [];
  }

  factory ReleaseInfo.parse({
    required String releaseTitle,
    String? fileName,
    String languageLine = '',
    String? movieTitle,
  }) {
    final raw = '$releaseTitle ${fileName ?? ''}';
    final n1 = _keepSymbols(raw); // keeps + - / for DD+ etc.
    final a1 = _alnum(raw); // letters/digits only, single spaces

    // ── Technical tags ─────────────────────────────────────────────────────
    String? resolution;
    if (RegExp(r'\b(?:2160p|4k|uhd)\b').hasMatch(n1)) {
      resolution = '4K';
    } else if (RegExp(r'\b1080[pi]\b').hasMatch(n1)) {
      resolution = '1080p';
    } else if (RegExp(r'\b720p\b').hasMatch(n1)) {
      resolution = '720p';
    } else if (RegExp(r'\b480p\b').hasMatch(n1)) {
      resolution = '480p';
    }

    String? source;
    if (RegExp(r'\bremux\b').hasMatch(n1)) {
      source = 'Remux';
    } else if (RegExp(r'\b(?:blu[ -]?ray|bd[ -]?rip|br[ -]?rip)\b')
        .hasMatch(n1)) {
      source = 'BluRay';
    } else if (RegExp(r'\bweb[ -]?dl\b').hasMatch(n1)) {
      source = 'WEB-DL';
    } else if (RegExp(r'\bweb[ -]?rip\b').hasMatch(n1)) {
      source = 'WEBRip';
    } else if (RegExp(r'\bhd[ -]?rip\b').hasMatch(n1)) {
      source = 'HDRip';
    } else if (RegExp(r'\bhdtv\b').hasMatch(n1)) {
      source = 'HDTV';
    } else if (RegExp(r'\b(?:dvd[ -]?rip|dvdscr)\b').hasMatch(n1)) {
      source = 'DVDRip';
    } else if (RegExp(r'\b(?:hdcam|camrip|telesync|hdts|cam)\b').hasMatch(n1)) {
      source = 'CAM';
    } else if (RegExp(r'\bweb\b').hasMatch(n1)) {
      source = 'WEB';
    }

    String? codec;
    if (RegExp(r'\b(?:x265|h[ -]?265|hevc)\b').hasMatch(n1)) {
      codec = 'HEVC';
    } else if (RegExp(r'\bav1\b').hasMatch(n1)) {
      codec = 'AV1';
    } else if (RegExp(r'\b(?:x264|h[ -]?264|avc)\b').hasMatch(n1)) {
      codec = 'x264';
    }

    final hasDv = RegExp(r'\b(?:dolby vision|dv|dovi)\b').hasMatch(n1);
    String? hdr;
    if (RegExp(r'\bhdr10(?:\+|plus)').hasMatch(n1)) {
      hdr = 'HDR10+';
    } else if (RegExp(r'\b(?:hdr10|hdr)\b').hasMatch(n1)) {
      hdr = 'HDR';
    }
    if (hasDv) hdr = hdr == null ? 'DV' : 'DV · $hdr';

    String? audio;
    if (n1.contains('atmos')) {
      audio = 'Atmos';
    } else if (RegExp(r'\btruehd\b').hasMatch(n1)) {
      audio = 'TrueHD';
    } else {
      final ddp = RegExp(r'\b(?:ddp|dd\+|eac3)\s?([257]) ?([01])\b').firstMatch(n1);
      final dd = RegExp(r'\bdd\s?([257]) ?([01])\b').firstMatch(n1);
      if (ddp != null) {
        audio = 'DD+ ${ddp.group(1)}.${ddp.group(2)}';
      } else if (dd != null) {
        audio = 'DD ${dd.group(1)}.${dd.group(2)}';
      } else if (RegExp(r'\bdts\b').hasMatch(n1)) {
        audio = 'DTS';
      } else if (RegExp(r'\baac\b').hasMatch(n1)) {
        audio = 'AAC';
      }
    }

    // ── Languages ──────────────────────────────────────────────────────────
    // Only look at the TAG part of the name. The movie's own title can
    // contain a language word ("The French Dispatch", "Hindi Medium"), so we
    // strip the title and start reading at the year / season marker.
    var region = a1;
    final title = _alnum(movieTitle ?? '');
    if (title.length >= 3) {
      region = region.replaceFirst(title, ' ');
    }
    final cut = RegExp(r'\b(?:19\d\d|20\d\d|s\d{1,2}(?: ?e\d{1,3})?)\b')
        .firstMatch(region);
    if (cut != null) region = region.substring(cut.start);
    region = '$region ${_alnum(languageLine)}';

    // "English Subs", "ESub" ... are subtitles, not English audio.
    var hasSubs = false;
    region = region.replaceAllMapped(
      RegExp(
          r'\b(?:e ?subs?|(?:english|eng|hindi|hin|multi|multiple) ?sub(?:s|titles?)?|subs?|subtitles?)\b'),
      (m) {
        hasSubs = true;
        return ' ';
      },
    );

    final found = <String>[];
    void add(String lang) {
      if (!found.contains(lang)) found.add(lang);
    }

    _languagePatterns.forEach((lang, pattern) {
      if (RegExp(pattern).hasMatch(region)) add(lang);
    });

    for (final m in RegExp(
            r'\b(?:hin|tam|tel|mal|kan|ben|mar|pun|eng|kor|jpn|fre|ger|spa|ita|rus|chi)(?: (?:hin|tam|tel|mal|kan|ben|mar|pun|eng|kor|jpn|fre|ger|spa|ita|rus|chi))+\b')
        .allMatches(region)) {
      for (final code in m.group(0)!.split(' ')) {
        final lang = _codeLanguages[code];
        if (lang != null) add(lang);
      }
    }

    // Flag emoji from Torrentio's language line.
    var indianFlag = false;
    final runes = languageLine.runes.toList();
    for (var i = 0; i + 1 < runes.length; i++) {
      final a = runes[i];
      final b = runes[i + 1];
      if (_isRegionalIndicator(a) && _isRegionalIndicator(b)) {
        final code = String.fromCharCodes(
            [0x41 + (a - 0x1F1E6), 0x41 + (b - 0x1F1E6)]);
        if (code == 'IN') {
          indianFlag = true;
        } else {
          final lang = _flagLanguages[code];
          if (lang != null) add(lang);
        }
        i++;
      }
    }

    final dual = RegExp(r'\bdual(?: ?audio)?\b').hasMatch(region);
    final multi =
        RegExp(r'\bmulti(?: ?audio| ?lang(?:uage)?s?)?\b').hasMatch(region);

    return ReleaseInfo(
      resolution: resolution,
      source: source,
      codec: codec,
      hdr: hdr,
      audio: audio,
      languages: List.unmodifiable(found),
      dualAudio: dual,
      multiAudio: multi,
      hasSubs: hasSubs,
      indianFlag: indianFlag,
    );
  }
}

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

/// lowercase, `._[](){}` -> space; keeps `+ - /`.
String _keepSymbols(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[._\[\](){}]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// lowercase, everything that isn't a letter/digit -> single space.
String _alnum(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// "15.32 GB" / "700 MB" -> bytes (null if it can't be read).
int? parseSizeToBytes(String? size) {
  if (size == null) return null;
  final m = RegExp(r'([\d.,]+)\s*([kmgt]i?b)', caseSensitive: false)
      .firstMatch(size);
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!.replaceAll(',', ''));
  if (value == null) return null;
  final unit = m.group(2)!.toLowerCase();
  const mult = {
    'kb': 1024.0,
    'kib': 1024.0,
    'mb': 1048576.0,
    'mib': 1048576.0,
    'gb': 1073741824.0,
    'gib': 1073741824.0,
    'tb': 1099511627776.0,
    'tib': 1099511627776.0,
  };
  final factor = mult[unit];
  if (factor == null) return null;
  return (value * factor).round();
}
