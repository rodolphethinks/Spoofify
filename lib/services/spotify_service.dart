import 'dart:convert';
import 'package:http/http.dart' as http;

class Track {
  final String title;
  final String artists;

  const Track({required this.title, required this.artists});
}

class SpotifySearchResult {
  final String name;
  final String type; // playlist, album, track
  final String url;
  final String subtitle;

  const SpotifySearchResult({
    required this.name,
    required this.type,
    required this.url,
    required this.subtitle,
  });
}

class SpotifyService {
  static final _urlRe = RegExp(
    r'https?://open\.spotify\.com/(playlist|album|track|episode|show)/([A-Za-z0-9]+)',
  );

  static bool isSpotifyUrl(String text) => _urlRe.hasMatch(text.trim());

  static String? _cachedToken;
  static int _tokenExpiry = 0;

  /// Get an anonymous access token from Spotify's web player page.
  static Future<String> _getAnonymousToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedToken != null && now < _tokenExpiry - 60000) {
      return _cachedToken!;
    }

    final response = await http.get(
      Uri.parse('https://open.spotify.com'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to get Spotify token: ${response.statusCode}');
    }

    final tokenRe = RegExp(r'"accessToken"\s*:\s*"([^"]+)"');
    final match = tokenRe.firstMatch(response.body);
    if (match == null) {
      throw Exception('Could not extract access token from Spotify page');
    }

    _cachedToken = match.group(1)!;

    final expiryRe = RegExp(r'"accessTokenExpirationTimestampMs"\s*:\s*(\d+)');
    final expiryMatch = expiryRe.firstMatch(response.body);
    if (expiryMatch != null) {
      _tokenExpiry = int.parse(expiryMatch.group(1)!);
    } else {
      _tokenExpiry = now + 3600000; // default 1h
    }

    return _cachedToken!;
  }

  /// Search Spotify for playlists/albums/tracks using the Web API.
  static Future<List<SpotifySearchResult>> search(String query) async {
    final token = await _getAnonymousToken();
    final encoded = Uri.encodeComponent(query);
    final url =
        'https://api.spotify.com/v1/search?q=$encoded&type=track,album,playlist&limit=10';

    final response = await http.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 401) {
      // Token expired, clear cache and retry once
      _cachedToken = null;
      _tokenExpiry = 0;
      final newToken = await _getAnonymousToken();
      final retryResponse = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $newToken'},
      );
      if (retryResponse.statusCode != 200) {
        throw Exception('Search failed: ${retryResponse.statusCode}');
      }
      return _parseSearchResponse(retryResponse.body);
    }

    if (response.statusCode != 200) {
      throw Exception('Search failed: ${response.statusCode}');
    }

    return _parseSearchResponse(response.body);
  }

  static List<SpotifySearchResult> _parseSearchResponse(String body) {
    final data = jsonDecode(body);
    final results = <SpotifySearchResult>[];

    // Parse tracks
    final tracks = data['tracks']?['items'] as List<dynamic>? ?? [];
    for (final item in tracks) {
      final name = item['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final artists = (item['artists'] as List<dynamic>?)
              ?.map((a) => a['name'] as String? ?? '')
              .join(', ') ??
          '';
      final spotifyUrl =
          item['external_urls']?['spotify'] as String? ?? '';
      if (spotifyUrl.isNotEmpty) {
        results.add(SpotifySearchResult(
          name: name,
          type: 'track',
          url: spotifyUrl,
          subtitle: artists,
        ));
      }
    }

    // Parse albums
    final albums = data['albums']?['items'] as List<dynamic>? ?? [];
    for (final item in albums) {
      final name = item['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final artists = (item['artists'] as List<dynamic>?)
              ?.map((a) => a['name'] as String? ?? '')
              .join(', ') ??
          '';
      final spotifyUrl =
          item['external_urls']?['spotify'] as String? ?? '';
      if (spotifyUrl.isNotEmpty) {
        results.add(SpotifySearchResult(
          name: name,
          type: 'album',
          url: spotifyUrl,
          subtitle: artists,
        ));
      }
    }

    // Parse playlists
    final playlists = data['playlists']?['items'] as List<dynamic>? ?? [];
    for (final item in playlists) {
      final name = item['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final owner = item['owner']?['display_name'] as String? ?? '';
      final spotifyUrl =
          item['external_urls']?['spotify'] as String? ?? '';
      if (spotifyUrl.isNotEmpty) {
        results.add(SpotifySearchResult(
          name: name,
          type: 'playlist',
          url: spotifyUrl,
          subtitle: owner,
        ));
      }
    }

    return results;
  }

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
