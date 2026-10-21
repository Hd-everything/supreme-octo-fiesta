import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'services/supabase_config.dart';

import 'project_library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.startsWith('https://') && supabasePublishableKey.isNotEmpty) {
    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabasePublishableKey);
      vyntraSupabaseConfigured = true;
    } catch (error) {
      debugPrint('Vyntra cloud services are unavailable: $error');
    }
  }
  runApp(VyntraStartup(preferences: SharedPreferences.getInstance()));
}

Future<void> _initializeAds() async {
  try {
    await MobileAds.instance.initialize();
  } catch (error) {
    debugPrint('Vyntra ads initialization failed: $error');
  }
}

class VyntraStartup extends StatefulWidget {
  const VyntraStartup({super.key, required this.preferences});

  final Future<SharedPreferences> preferences;

  @override
  State<VyntraStartup> createState() => _VyntraStartupState();
}

class _VyntraStartupState extends State<VyntraStartup> {
  late Future<SharedPreferences> _preferences = widget.preferences;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeAds());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SharedPreferences>(
        future: _preferences,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _vyntraTheme(),
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.movie_edit_outlined, size: 48),
                      const SizedBox(height: 16),
                      const Text('Vyntra could not load project storage.'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => setState(
                          () => _preferences = SharedPreferences.getInstance(),
                        ),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _vyntraTheme(),
              home: const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.movie_edit_outlined, size: 54, color: Color(0xFF62E6C5)),
                      SizedBox(height: 14),
                      Text('VYNTRA', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
                      SizedBox(height: 6),
                      Text('Make every frame count', style: TextStyle(color: Colors.white54)),
                      SizedBox(height: 22),
                      SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
            );
          }
          return VyntraApp(preferences: snapshot.data!);
        },
      );
}

ThemeData _vyntraTheme() {
  const background = Color(0xFF080A0D);
  const surface = Color(0xFF15191E);
  const accent = Color(0xFF62E6C5);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: surface,
  ).copyWith(
    primary: accent,
    onPrimary: const Color(0xFF05251D),
    surface: surface,
    onSurface: const Color(0xFFF4F6F7),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF252B31)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF252B31), space: 1),
    sliderTheme: const SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      overlayColor: Color(0x2262E6C5),
    ),
    textTheme: ThemeData.dark().textTheme.apply(
      bodyColor: const Color(0xFFF4F6F7),
      displayColor: const Color(0xFFF4F6F7),
    ),
  );
}

class VyntraApp extends StatelessWidget {
  const VyntraApp({super.key, required this.preferences});

  final SharedPreferences preferences;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vyntra — Video Editor',
        debugShowCheckedModeBanner: false,
        theme: _vyntraTheme(),
        home: ProjectLibraryScreen(preferences: preferences),
      );
}
