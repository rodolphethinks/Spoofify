import 'dart:convert';
import 'package:http/http.dart' as http;
import 'log_service.dart';

class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({required this.time, required this.text});
}

class LyricsService {
  /// Fetch synced lyrics from LRCLIB API.
  /// Returns list of timed lyric lines, or null if not found.
  static Future<List<LyricLine>?> getSyncedLyrics(
      String title, String artist) async {
    final params = {
      'track_name': title,
      'artist_name': artist,
    };
    final uri =
        Uri.https('lrclib.net', '/api/get', params);

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'Spoofify/1.0',
      });

      if (response.statusCode != 200) {
        appLog('[Lyrics] Not found: ${response.statusCode}', level: LogLevel.warning);
        return null;
      }

      final data = jsonDecode(response.body);
      final syncedLyrics = data['syncedLyrics'] as String?;
      if (syncedLyrics == null || syncedLyrics.isEmpty) {
        // Fall back to plain lyrics
        final plain = data['plainLyrics'] as String?;
        if (plain != null && plain.isNotEmpty) {
          return plain
              .split('\n')
              .map((l) => LyricLine(time: Duration.zero, text: l))
              .toList();
        }
        return null;
      }

      return _parseLrc(syncedLyrics);
    } catch (e) {
      appLog('[Lyrics] Error: $e', level: LogLevel.error);
      return null;
    }
  }

  static List<LyricLine> _parseLrc(String lrc) {
    final lines = <LyricLine>[];
    final re = RegExp(r'\[(\d+):(\d+)\.(\d+)\]\s*(.*)');

    for (final line in lrc.split('\n')) {
      final match = re.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final centis = int.parse(match.group(3)!);
        final text = match.group(4)!;
        final time = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: centis * 10,
        );
        lines.add(LyricLine(time: time, text: text));
      }
    }
    return lines;
  }
}
