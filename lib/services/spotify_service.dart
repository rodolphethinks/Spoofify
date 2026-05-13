import 'dart:convert';
import 'package:http/http.dart' as http;

class Track {
  final String title;
  final String artists;

  const Track({required this.title, required this.artists});
}

class SpotifyService {
  static final _urlRe = RegExp(
    r'https?://open\.spotify\.com/(playlist|album|track|episode|show)/([A-Za-z0-9]+)',
  );

  /// Fetches track list from any public Spotify URL.
  /// Returns (playlistName, tracks).
  static Future<(String, List<Track>)> getTracks(String url) async {
    final m = _urlRe.firstMatch(url);
    if (m == null) throw Exception('Invalid Spotify URL');

    final type = m.group(1)!;
    final id = m.group(2)!;
    final embedUrl = 'https://open.spotify.com/embed/$type/$id';

    final response = await http.get(
      Uri.parse(embedUrl),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/136.0.0.0 Mobile Safari/537.36',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch Spotify embed: ${response.statusCode}');
    }

    // Extract __NEXT_DATA__ JSON from the HTML
    final re = RegExp(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', dotAll: true);
    final match = re.firstMatch(response.body);
    if (match == null) throw Exception('Could not find track data in Spotify page');

    final data = jsonDecode(match.group(1)!);

    // Navigate to the entity data
    final props = data['props'] as Map<String, dynamic>;
    final pageProps = props['pageProps'] as Map<String, dynamic>;
    final state = pageProps['state'] as Map<String, dynamic>;
    final entities = state['data']?['entity'] as Map<String, dynamic>?;

    String playlistName = 'Playlist';
    final tracks = <Track>[];

    if (entities != null) {
      playlistName = entities['name'] as String? ?? 'Playlist';

      final items = entities['trackList'] as List<dynamic>?;
      if (items != null) {
        for (final item in items) {
          final trackName = item['title'] as String? ?? '';
          final subtitle = (item['subtitle'] as String? ?? '')
              .replaceAll('\u00a0', ' ')
              .trim();
          if (trackName.isNotEmpty) {
            tracks.add(Track(title: trackName, artists: subtitle));
          }
        }
      }
    }

    if (tracks.isEmpty) throw Exception('No tracks found in playlist');
    return (playlistName, tracks);
  }
}
