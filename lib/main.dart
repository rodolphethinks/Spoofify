import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/player_provider.dart';
import 'screens/home_screen.dart';

late AudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init(
    builder: () => SpoofifyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.spoofify.audio',
      androidNotificationChannelName: 'Spoofify',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => PlayerProvider(audioHandler as SpoofifyAudioHandler),
      child: const SpoofifyApp(),
    ),
  );
}

class SpoofifyApp extends StatelessWidget {
  const SpoofifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spoofify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1DB954),
          surface: Color(0xFF121212),
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const HomeScreen(),
    );
  }
}
