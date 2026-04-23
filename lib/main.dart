import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'providers/tmdb_provider.dart';
import 'providers/watchlist_provider.dart';
import 'screens/splash_screen.dart';

// ── Replace these before deploying ────────────────────────────────────────────
const _supabaseUrl = 'https://dmiqpgmvutcameekywul.supabase.co';
const _supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRtaXFwZ212dXRjYW1lZWt5d3VsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY0Njk1MzEsImV4cCI6MjA5MjA0NTUzMX0.7C3qPi5IdVNcipNo08E0zMzLHB9NOvyu5qqITqCnW7U';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  
  // System UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Supabase
  await Supabase.initialize(
  url: _supabaseUrl,
  anonKey: _supabaseAnonKey,
  realtimeClientOptions: const RealtimeClientOptions(
    eventsPerSecond: 10,
  ),
);

  // Hive (watchlist only)
  try {
    await Hive.initFlutter();
    await Hive.openBox('watchlist');
    await Hive.openBox('settings');
  } catch (e) {
    debugPrint('Hive init error, retrying clean: $e');
    try {
      await Hive.deleteBoxFromDisk('watchlist');
      await Hive.deleteBoxFromDisk('settings');
      await Hive.openBox('watchlist');
      await Hive.openBox('settings');
    } catch (_) {}
  }

  runApp(const InFlexApp());
}

class InFlexApp extends StatelessWidget {
  const InFlexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TmdbProvider()),
        ChangeNotifierProvider(create: (_) => WatchlistProvider()),
      ],
      child: MaterialApp(
        title: 'InFlex',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFFCC00),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF050508),
          useMaterial3: true,
        ),
        home: const SplashScreen(),
      ),
    );
  }
}
