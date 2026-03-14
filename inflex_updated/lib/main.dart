import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'providers/tmdb_provider.dart';
import 'providers/watchlist_provider.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF050508),
  ));

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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TmdbProvider()),
        ChangeNotifierProvider(create: (_) => WatchlistProvider()),
      ],
      child: const InFlexApp(),
    ),
  );
}

class InFlexApp extends StatelessWidget {
  const InFlexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InFlex',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050508),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFCC00),
          secondary: Color(0xFFFFD740),
          surface: Color(0xFF0E0E16),
          onPrimary: Color(0xFF000000),
          onSecondary: Color(0xFF000000),
          onSurface: Colors.white,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
          bodySmall: TextStyle(color: Colors.white70),
          titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          titleMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          titleSmall: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF050508),
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.white),
        ),
        cardTheme: CardTheme(
          color: const Color(0xFF0E0E16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 8,
        ),
      ),
      builder: (context, child) {
        ErrorWidget.builder = (FlutterErrorDetails details) {
          return Scaffold(
            backgroundColor: const Color(0xFF050508),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFCC00), size: 52),
                  const SizedBox(height: 16),
                  const Text('Something went wrong',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(details.exceptionAsString(),
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                        textAlign: TextAlign.center, maxLines: 5, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          );
        };
        return child!;
      },
      home: const SplashScreen(),
    );
  }
}
