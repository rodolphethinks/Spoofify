import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'log_service.dart';
import 'spotify_service.dart';
import 'youtube_service.dart';

class DownloadedTrack {
  final String title;
  final String artists;
  final String? filePath;
  final bool downloaded;

  const DownloadedTrack({
    required this.title,
    required this.artists,
    this.filePath,
    this.downloaded = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'artists': artists,
        'filePath': filePath,
        'downloaded': downloaded,
      };

  factory DownloadedTrack.fromJson(Map<String, dynamic> json) =>
      DownloadedTrack(
        title: json['title'] as String,
        artists: json['artists'] as String,
        filePath: json['filePath'] as String?,
        downloaded: json['downloaded'] as bool? ?? false,
      );

  String get uniqueKey => '${artists.toLowerCase()}|${title.toLowerCase()}';
}

class SavedPlaylist {
  final String name;
  final String url;
  final List<DownloadedTrack> tracks;
  final bool isFavorite;

  SavedPlaylist({
    required this.name,
    required this.url,
    required this.tracks,
    this.isFavorite = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'isFavorite': isFavorite,
      };

  factory SavedPlaylist.fromJson(Map<String, dynamic> json) => SavedPlaylist(
        name: json['name'] as String,
        url: json['url'] as String,
        tracks: (json['tracks'] as List)
            .map((t) => DownloadedTrack.fromJson(t as Map<String, dynamic>))
            .toList(),
        isFavorite: json['isFavorite'] as bool? ?? false,
      );

  int get downloadedCount => tracks.where((t) => t.downloaded).length;
  bool get isFullyDownloaded => tracks.every((t) => t.downloaded);
}

class OfflineService {
  static OfflineService? _instance;
  static OfflineService get instance => _instance ??= OfflineService._();
  OfflineService._();

  List<SavedPlaylist> _playlists = [];
  List<SavedPlaylist> get playlists => _playlists;
  List<SavedPlaylist> get favorites =>
      _playlists.where((p) => p.isFavorite).toList();

  bool _loaded = false;

  Future<String> get _dataDir async {
    final dir = await getApplicationDocumentsDirectory();
    final offlineDir = Directory('${dir.path}/offline');
    if (!await offlineDir.exists()) {
      await offlineDir.create(recursive: true);
    }
    return offlineDir.path;
  }

  Future<String> get _audioDir async {
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return audioDir.path;
  }

  Future<File> get _dbFile async {
    final dir = await _dataDir;
    return File('$dir/playlists.json');
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final file = await _dbFile;
      if (await file.exists()) {
        final json = await file.readAsString();
        final list = jsonDecode(json) as List;
        _playlists =
            list.map((e) => SavedPlaylist.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      appLog('[Offline] Load error: $e', level: LogLevel.error);
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final file = await _dbFile;
    await file.writeAsString(jsonEncode(_playlists.map((p) => p.toJson()).toList()));
  }

  /// Get a saved playlist by URL (null if not saved)
  SavedPlaylist? getPlaylist(String url) {
    try {
      return _playlists.firstWhere((p) => p.url == url);
    } catch (_) {
      return null;
    }
  }

  /// Toggle favorite status
  Future<void> toggleFavorite(String url) async {
    final idx = _playlists.indexWhere((p) => p.url == url);
    if (idx < 0) return;
    final p = _playlists[idx];
    _playlists[idx] = SavedPlaylist(
      name: p.name,
      url: p.url,
      tracks: p.tracks,
      isFavorite: !p.isFavorite,
    );
    await _save();
  }

  /// Download a single track, returns file path
  Future<String?> downloadTrack(String title, String artists) async {
    final dir = await _audioDir;
    // Check if already downloaded across any playlist
    for (final playlist in _playlists) {
      for (final track in playlist.tracks) {
        if (track.uniqueKey == '${artists.toLowerCase()}|${title.toLowerCase()}' &&
            track.downloaded &&
            track.filePath != null) {
          final file = File(track.filePath!);
          if (await file.exists()) {
            appLog('[Offline] Already downloaded: $title');
            return track.filePath;
          }
        }
      }
    }

    // Download via YoutubeService (downloads to permanent dir)
    final source = await YoutubeService.getAudioSourceToDir(title, artists, dir);
    return source;
  }

  /// Download all tracks in a playlist
  Future<void> downloadPlaylist(
    String name,
    String url,
    List<Track> tracks,
    void Function(int downloaded, int total) onProgress,
  ) async {
    // Find or create saved playlist
    var idx = _playlists.indexWhere((p) => p.url == url);
    if (idx < 0) {
      _playlists.add(SavedPlaylist(
        name: name,
        url: url,
        tracks: tracks
            .map((t) => DownloadedTrack(title: t.title, artists: t.artists))
            .toList(),
        isFavorite: true,
      ));
      idx = _playlists.length - 1;
      await _save();
    }

    final playlist = _playlists[idx];
    int completed = 0;

    for (int i = 0; i < playlist.tracks.length; i++) {
      final track = playlist.tracks[i];
      if (track.downloaded && track.filePath != null) {
        final file = File(track.filePath!);
        if (await file.exists()) {
          completed++;
          onProgress(completed, playlist.tracks.length);
          continue;
        }
      }

      final filePath = await downloadTrack(track.title, track.artists);
      final updatedTracks = List<DownloadedTrack>.from(playlist.tracks);
      updatedTracks[i] = DownloadedTrack(
        title: track.title,
        artists: track.artists,
        filePath: filePath,
        downloaded: filePath != null,
      );
      _playlists[idx] = SavedPlaylist(
        name: playlist.name,
        url: playlist.url,
        tracks: updatedTracks,
        isFavorite: playlist.isFavorite,
      );
      completed++;
      onProgress(completed, playlist.tracks.length);
      await _save();
    }
  }

  /// Refresh a playlist - check for new/deleted songs
  Future<(List<Track> added, List<String> removed)> refreshPlaylist(
      String url) async {
    final idx = _playlists.indexWhere((p) => p.url == url);
    if (idx < 0) return (<Track>[], <String>[]);

    final playlist = _playlists[idx];
    final (_, freshTracks) = await SpotifyService.getTracks(url);

    final oldKeys =
        playlist.tracks.map((t) => t.uniqueKey).toSet();
    final newKeys = freshTracks
        .map((t) => '${t.artists.toLowerCase()}|${t.title.toLowerCase()}')
        .toSet();

    // Find added tracks
    final added = freshTracks
        .where((t) =>
            !oldKeys.contains('${t.artists.toLowerCase()}|${t.title.toLowerCase()}'))
        .toList();

    // Find removed tracks
    final removedKeys = oldKeys.difference(newKeys);
    final removed = playlist.tracks
        .where((t) => removedKeys.contains(t.uniqueKey))
        .map((t) => t.title)
        .toList();

    // Delete audio files for removed songs (only if not in another playlist)
    for (final track in playlist.tracks) {
      if (removedKeys.contains(track.uniqueKey) &&
          track.filePath != null &&
          track.downloaded) {
        final isInOtherPlaylist = _playlists.any((p) =>
            p.url != url &&
            p.tracks.any((t) =>
                t.uniqueKey == track.uniqueKey && t.downloaded));
        if (!isInOtherPlaylist) {
          try {
            await File(track.filePath!).delete();
            appLog('[Offline] Deleted orphan: ${track.filePath}');
          } catch (_) {}
        }
      }
    }

    // Update playlist with new track list (preserve download state for existing)
    final updatedTracks = freshTracks.map((t) {
      final key = '${t.artists.toLowerCase()}|${t.title.toLowerCase()}';
      final existing = playlist.tracks.where((e) => e.uniqueKey == key).firstOrNull;
      if (existing != null) return existing;
      return DownloadedTrack(title: t.title, artists: t.artists);
    }).toList();

    _playlists[idx] = SavedPlaylist(
      name: playlist.name,
      url: playlist.url,
      tracks: updatedTracks,
      isFavorite: playlist.isFavorite,
    );
    await _save();

    return (added, removed);
  }
}
