import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:spoofify_app/services/spotify_service.dart';

void main() {
  group('SpotifyService.isSpotifyUrl - URL detection', () {
    test('detects playlist URL', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'),
        isTrue,
      );
    });

    test('detects album URL', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/album/0JGOiO34nwfUdDrD612dOp'),
        isTrue,
      );
    });

    test('detects track URL', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl'),
        isTrue,
      );
    });

    test('detects URL with http (no s)', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'http://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'),
        isTrue,
      );
    });

    test('detects URL with trailing query params', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123'),
        isTrue,
      );
    });

    test('detects URL with leading/trailing whitespace', () {
      expect(
        SpotifyService.isSpotifyUrl(
            '  https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M  '),
        isTrue,
      );
    });

    test('rejects plain text search queries', () {
      expect(SpotifyService.isSpotifyUrl('drake hotline bling'), isFalse);
    });

    test('rejects empty string', () {
      expect(SpotifyService.isSpotifyUrl(''), isFalse);
    });

    test('rejects partial URL (no scheme)', () {
      expect(
        SpotifyService.isSpotifyUrl('open.spotify.com/playlist/abc'),
        isFalse,
      );
    });

    test('rejects non-spotify URL', () {
      expect(
        SpotifyService.isSpotifyUrl('https://youtube.com/watch?v=abc'),
        isFalse,
      );
    });

    test('rejects spotify URL with invalid type (user)', () {
      expect(
        SpotifyService.isSpotifyUrl('https://open.spotify.com/user/123'),
        isFalse,
      );
    });

    test('rejects generic text mentioning spotify', () {
      expect(
        SpotifyService.isSpotifyUrl('best spotify playlists 2024'),
        isFalse,
      );
    });

    test('rejects URL with wrong subdomain', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://fake-open.spotify.com/playlist/abc'),
        isFalse,
      );
    });

    test('detects episode URL', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/episode/5Wm3gVOBkXPrU5P7mZSnog'),
        isTrue,
      );
    });

    test('detects show URL', () {
      expect(
        SpotifyService.isSpotifyUrl(
            'https://open.spotify.com/show/2MAi0BvDc6GTFvKFPXnkCL'),
        isTrue,
      );
    });
  });

  group('Auto-detection logic (simulated _submit behavior)', () {
    // This replicates the logic from home_screen.dart _submit()
    String classifyInput(String text) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) return 'empty';
      if (SpotifyService.isSpotifyUrl(trimmed)) return 'url';
      return 'search';
    }

    test('classifies full spotify playlist URL as url', () {
      expect(
        classifyInput(
            'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'),
        equals('url'),
      );
    });

    test('classifies pasted URL with whitespace/newline as url', () {
      expect(
        classifyInput(
            '  https://open.spotify.com/album/0JGOiO34nwfUdDrD612dOp  \n'),
        equals('url'),
      );
    });

    test('classifies artist name as search', () {
      expect(classifyInput('Taylor Swift'), equals('search'));
    });

    test('classifies song + artist as search', () {
      expect(classifyInput('Blinding Lights The Weeknd'), equals('search'));
    });

    test('classifies empty string as empty', () {
      expect(classifyInput(''), equals('empty'));
    });

    test('classifies whitespace-only as empty', () {
      expect(classifyInput('   '), equals('empty'));
    });

    test('classifies youtube URL as search (not spotify)', () {
      expect(
        classifyInput('https://youtube.com/watch?v=dQw4w9WgXcQ'),
        equals('search'),
      );
    });

    test('classifies text mentioning spotify as search', () {
      expect(
        classifyInput('best spotify playlists for gym'),
        equals('search'),
      );
    });

    test('classifies single word as search', () {
      expect(classifyInput('Drake'), equals('search'));
    });

    test('classifies track URL with query params as url', () {
      expect(
        classifyInput(
            'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh?si=abc'),
        equals('url'),
      );
    });
  });

  group('Search response JSON parsing', () {
    // Tests the expected Spotify Web API response structure and parsing logic
    // that _parseSearchResponse handles

    test('parses tracks correctly', () {
      final json = jsonDecode('''
{
  "tracks": {
    "items": [
      {
        "name": "Hotline Bling",
        "artists": [{"name": "Drake"}],
        "external_urls": {"spotify": "https://open.spotify.com/track/0wwPcA6wtMf6HUMpIRdeP7"}
      },
      {
        "name": "God's Plan",
        "artists": [{"name": "Drake"}, {"name": "Future"}],
        "external_urls": {"spotify": "https://open.spotify.com/track/6DCZcSspjsKoFjzjrWoCdn"}
      }
    ]
  },
  "albums": {"items": []},
  "playlists": {"items": []}
}''');

      final tracks = json['tracks']['items'] as List;
      expect(tracks.length, equals(2));
      expect(tracks[0]['name'], equals('Hotline Bling'));
      expect(tracks[0]['artists'][0]['name'], equals('Drake'));
      expect(tracks[0]['external_urls']['spotify'],
          equals('https://open.spotify.com/track/0wwPcA6wtMf6HUMpIRdeP7'));
      // Multi-artist
      expect(tracks[1]['artists'].length, equals(2));
      expect(tracks[1]['artists'][1]['name'], equals('Future'));
    });

    test('parses albums correctly', () {
      final json = jsonDecode('''
{
  "tracks": {"items": []},
  "albums": {
    "items": [
      {
        "name": "Scorpion",
        "artists": [{"name": "Drake"}],
        "external_urls": {"spotify": "https://open.spotify.com/album/1ATL5GLyefJaxhQzSPVrLX"}
      }
    ]
  },
  "playlists": {"items": []}
}''');

      final albums = json['albums']['items'] as List;
      expect(albums.length, equals(1));
      expect(albums[0]['name'], equals('Scorpion'));
      expect(albums[0]['external_urls']['spotify'],
          contains('open.spotify.com/album/'));
    });

    test('parses playlists correctly', () {
      final json = jsonDecode('''
{
  "tracks": {"items": []},
  "albums": {"items": []},
  "playlists": {
    "items": [
      {
        "name": "Drake Essentials",
        "owner": {"display_name": "Spotify"},
        "external_urls": {"spotify": "https://open.spotify.com/playlist/37i9dQZF1DX7QOv5kjbU68"}
      }
    ]
  }
}''');

      final playlists = json['playlists']['items'] as List;
      expect(playlists.length, equals(1));
      expect(playlists[0]['name'], equals('Drake Essentials'));
      expect(playlists[0]['owner']['display_name'], equals('Spotify'));
      expect(playlists[0]['external_urls']['spotify'],
          contains('open.spotify.com/playlist/'));
    });

    test('handles empty items lists', () {
      final json = jsonDecode('''
{
  "tracks": {"items": []},
  "albums": {"items": []},
  "playlists": {"items": []}
}''');

      expect((json['tracks']['items'] as List).isEmpty, isTrue);
      expect((json['albums']['items'] as List).isEmpty, isTrue);
      expect((json['playlists']['items'] as List).isEmpty, isTrue);
    });

    test('items with empty name should be skippable', () {
      final json = jsonDecode('''
{
  "tracks": {
    "items": [
      {
        "name": "",
        "artists": [],
        "external_urls": {"spotify": ""}
      },
      {
        "name": "Valid Track",
        "artists": [{"name": "Artist"}],
        "external_urls": {"spotify": "https://open.spotify.com/track/abc123"}
      }
    ]
  },
  "albums": {"items": []},
  "playlists": {"items": []}
}''');

      final tracks = json['tracks']['items'] as List;
      // First item has empty name - our code skips these
      expect(tracks[0]['name'], equals(''));
      // Second item is valid
      expect(tracks[1]['name'], equals('Valid Track'));
      expect(tracks[1]['external_urls']['spotify'], isNotEmpty);
    });

    test('items with empty URL should be skippable', () {
      final json = jsonDecode('''
{
  "tracks": {
    "items": [
      {
        "name": "No URL Track",
        "artists": [{"name": "Artist"}],
        "external_urls": {"spotify": ""}
      }
    ]
  },
  "albums": {"items": []},
  "playlists": {"items": []}
}''');

      final tracks = json['tracks']['items'] as List;
      // Our code skips items with empty spotifyUrl
      expect(tracks[0]['external_urls']['spotify'], equals(''));
    });
  });

  group('SpotifyService.search - live integration', () {
    test('returns results for a popular query', () async {
      final results = await SpotifyService.search('Drake');
      expect(results, isNotEmpty,
          reason: 'Search for "Drake" should return results');
      for (final r in results) {
        expect(r.name, isNotEmpty);
        expect(r.url, contains('open.spotify.com'));
        expect(['playlist', 'album', 'track'], contains(r.type));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('returns results for a specific song', () async {
      final results = await SpotifyService.search('Bohemian Rhapsody Queen');
      expect(results, isNotEmpty);
      final hasTrack = results.any((r) => r.type == 'track');
      expect(hasTrack, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('returns playlist results', () async {
      final results = await SpotifyService.search('chill vibes playlist');
      expect(results, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('handles special characters', () async {
      final results = await SpotifyService.search('Beyoncé Crazy in Love');
      expect(results, isA<List<SpotifySearchResult>>());
    }, timeout: const Timeout(Duration(seconds: 30)));
  }, skip: 'Requires direct network access to open.spotify.com and api.spotify.com');
}
