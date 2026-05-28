import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../services/offline_service.dart';
import '../services/spotify_service.dart';
import '../services/youtube_service.dart';

enum TrackState { idle, loading, ready, error }

enum SpoofifyRepeatMode { off, all, one }

class TrackModel {
  final Track track;
  TrackState state;
  String? error;
  AudioSource? preloadedSource;

  TrackModel(this.track) : state = TrackState.idle;
}

/// Audio handler for media notification controls
class SpoofifyAudioHandler extends BaseAudioHandler with SeekHandler {
  PlayerProvider? _provider;

  void _updatePlaybackState() {
    final provider = _provider;
    if (provider == null) return;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        provider.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: provider.isPlaying,
      updatePosition: provider.position,
    ));
  }

  @override
  Future<void> play() async => _provider?.togglePause();

  @override
  Future<void> pause() async => _provider?.togglePause();

  @override
  Future<void> skipToNext() async => _provider?.seekNext();

  @override
  Future<void> skipToPrevious() async => _provider?.seekPrev();

  @override
  Future<void> seek(Duration position) async => _provider?.seekTo(position);

  @override
  Future<void> stop() async {
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }
}

class PlayerProvider extends ChangeNotifier {
  final _player = AudioPlayer();
  final _random = Random();
  final SpoofifyAudioHandler _audioHandler;

  String playlistName = '';
  List<TrackModel> tracks = [];
  int currentIndex = -1;
  bool isPlaying = false;
  bool isLoadingPlaylist = false;
  String? playlistError;
  bool shuffleEnabled = false;
  SpoofifyRepeatMode repeatMode = SpoofifyRepeatMode.off;
  List<String> playlistHistory = [];

  int _playSeq = 0;
  bool _preloadingNext = false;
  int _preloadedIndex = -1;
  StreamSubscription<Duration>? _preloadSub;
  List<Track> queue = [];
  String? currentPlaylistUrl;
  bool isDownloading = false;
  int downloadProgress = 0;
  int downloadTotal = 0;

  PlayerProvider(this._audioHandler) {
    _audioHandler._provider = this;
    _init();
    _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _advance();
      }
      _audioHandler._updatePlaybackState();
      notifyListeners();
    });
  }

  Future<void> _init() async {
    try {
      await OfflineService.instance.load();
      await _loadHistory();
      notifyListeners();
    } catch (e) {
      debugPrint('[Player] Init error: $e');
    }
  }

  OfflineService get offline => OfflineService.instance;
  List<SavedPlaylist> get favorites => OfflineService.instance.favorites;

  Future<File> get _historyFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/playlist_history.json');
  }

  Future<void> _loadHistory() async {
    try {
      final file = await _historyFile;
      if (await file.exists()) {
        final json = await file.readAsString();
        playlistHistory = List<String>.from(jsonDecode(json));
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    final file = await _historyFile;
    await file.writeAsString(jsonEncode(playlistHistory));
  }

  Future<void> loadPlaylist(String url) async {
    debugPrint('[Spotify] Loading: $url');
    isLoadingPlaylist = true;
    playlistError = null;
    tracks = [];
    playlistName = '';
    currentPlaylistUrl = url;
    notifyListeners();

    try {
      // Check if we have this playlist saved offline
      final saved = OfflineService.instance.getPlaylist(url);
      if (saved != null && saved.isFullyDownloaded) {
        debugPrint('[Offline] Loading saved playlist: ${saved.name}');
        playlistName = saved.name;
        tracks = saved.tracks
            .map((t) => TrackModel(Track(title: t.title, artists: t.artists)))
            .toList();
        // Add to history
        final entry = '$playlistName\n$url';
        playlistHistory.remove(entry);
        playlistHistory.insert(0, entry);
        if (playlistHistory.length > 20) {
          playlistHistory = playlistHistory.sublist(0, 20);
        }
        _saveHistory();
      } else {
        // Fetch from Spotify
        final (name, rawTracks) = await SpotifyService.getTracks(url);
        debugPrint('[Spotify] Got ${rawTracks.length} tracks: $name');
        playlistName = name;
        tracks = rawTracks.map(TrackModel.new).toList();

        // Add to history
        final entry = '$name\n$url';
        playlistHistory.remove(entry);
        playlistHistory.insert(0, entry);
        if (playlistHistory.length > 20) {
          playlistHistory = playlistHistory.sublist(0, 20);
        }
        _saveHistory();
      }
    } catch (e, st) {
      debugPrint('[Spotify] ERROR: $e');
      debugPrint('[Spotify] STACK: $st');
      // If fetch failed, try loading from offline cache
      final saved = OfflineService.instance.getPlaylist(url);
      if (saved != null) {
        playlistName = saved.name;
        tracks = saved.tracks
            .map((t) => TrackModel(Track(title: t.title, artists: t.artists)))
            .toList();
      } else {
        playlistError = e.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      isLoadingPlaylist = false;
      notifyListeners();
    }
  }

  /// Play a list of tracks directly (e.g. from YouTube search results)
  void playSearchResults(List<Track> trackList, String name, int startIndex) {
    tracks = trackList.map(TrackModel.new).toList();
    playlistName = name;
    currentPlaylistUrl = null;
    playlistError = null;
    notifyListeners();
    playTrack(startIndex);
  }

  Future<void> playTrack(int index) async {
    if (index < 0 || index >= tracks.length) return;
    final seq = ++_playSeq;
    debugPrint('[Player] playTrack($index) seq=$seq: ${tracks[index].track.title}');

    currentIndex = index;
    final model = tracks[index];
    notifyListeners();

    _setupPreloadListener();

    // Check if this track was preloaded
    if (model.preloadedSource != null) {
      debugPrint('[Player] Using preloaded source for ${model.track.title}');
      model.state = TrackState.ready;
      notifyListeners();
      await _loadAndPlay(model.preloadedSource!);
      model.preloadedSource = null;
      return;
    }

    model.state = TrackState.loading;
    model.error = null;
    notifyListeners();

    // Try offline source first
    final offlineSource = await _getOfflineSource(model);
    if (seq != _playSeq) return;
    if (offlineSource != null) {
      debugPrint('[Player] Playing from offline storage');
      model.state = TrackState.ready;
      notifyListeners();
      await _loadAndPlay(offlineSource);
      return;
    }

    AudioSource? source;
    try {
      if (model.track.youtubeUrl != null) {
        source = await YoutubeService.getAudioSourceByUrl(
          model.track.youtubeUrl!,
          model.track.title,
        );
      } else {
        source = await YoutubeService.getAudioSource(
          model.track.title,
          model.track.artists,
        );
      }
    } catch (e) {
      debugPrint('[Player] YouTube error: $e');
      if (seq != _playSeq) return;
      model.state = TrackState.error;
      model.error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      // Delay before advancing so user can see the error
      await Future.delayed(const Duration(seconds: 2));
      if (seq == _playSeq) _advance();
      return;
    }

    if (seq != _playSeq) {
      debugPrint('[Player] Aborted seq=$seq (current=$_playSeq)');
      return;
    }

    if (source == null) {
      debugPrint('[Player] No source found for ${model.track.title}');
      model.state = TrackState.error;
      model.error = 'Not found on YouTube';
      notifyListeners();
      // Delay before advancing so user can see the error
      await Future.delayed(const Duration(seconds: 2));
      if (seq == _playSeq) _advance();
      return;
    }

    debugPrint('[Player] Got source, loading...');
    model.state = TrackState.ready;
    notifyListeners();

    await _loadAndPlay(source);
  }

  Future<void> _loadAndPlay(AudioSource source) async {
    debugPrint('[Player] setAudioSource...');
    try {
      await _player.setAudioSource(source);
      _updateNotificationMetadata();
      debugPrint('[Player] play()');
      await _player.play();
      debugPrint('[Player] playing!');
    } catch (e, st) {
      debugPrint('[Player] PLAYBACK ERROR: $e');
      debugPrint('[Player] STACK: $st');
      if (currentIndex >= 0) {
        tracks[currentIndex].state = TrackState.error;
        tracks[currentIndex].error = 'Playback failed: $e';
        notifyListeners();
      }
    }
  }

  void _updateNotificationMetadata() {
    if (currentIndex < 0 || currentIndex >= tracks.length) return;
    final track = tracks[currentIndex].track;
    _audioHandler.mediaItem.add(MediaItem(
      id: '${track.title}_${track.artists}',
      title: track.title,
      artist: track.artists,
      album: playlistName,
    ));
  }

  int _getNextIndex() {
    if (shuffleEnabled) {
      if (tracks.length <= 1) return 0;
      int next;
      do {
        next = _random.nextInt(tracks.length);
      } while (next == currentIndex);
      return next;
    } else {
      return currentIndex + 1;
    }
  }

  void _advance() {
    if (repeatMode == SpoofifyRepeatMode.one) {
      playTrack(currentIndex);
      return;
    }
    // Play from queue first
    if (queue.isNotEmpty) {
      _playFromQueue();
      return;
    }
    final next = _getNextIndex();
    if (next < tracks.length) {
      playTrack(next);
    } else if (repeatMode == SpoofifyRepeatMode.all) {
      playTrack(0);
    }
  }

  Future<void> _playFromQueue() async {
    final track = queue.removeAt(0);
    notifyListeners();
    // Find in current track list or create temporary entry
    final idx = tracks.indexWhere(
        (m) => m.track.title == track.title && m.track.artists == track.artists);
    if (idx >= 0) {
      playTrack(idx);
    } else {
      // Add as temporary track at end and play it
      tracks.add(TrackModel(track));
      playTrack(tracks.length - 1);
    }
  }

  void addToQueue(Track track) {
    queue.add(track);
    debugPrint('[Player] Queue add: ${track.title} (queue=${queue.length})');
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index >= 0 && index < queue.length) {
      queue.removeAt(index);
      notifyListeners();
    }
  }

  void clearQueue() {
    queue.clear();
    notifyListeners();
  }

  void _setupPreloadListener() {
    _preloadSub?.cancel();
    _preloadingNext = false;
    _preloadedIndex = -1;
    _preloadSub = _player.positionStream.listen((pos) {
      final dur = _player.duration;
      if (dur == null || dur.inSeconds < 20) return;
      final remaining = dur - pos;
      if (remaining.inSeconds <= 15 && !_preloadingNext) {
        _preloadNextTrack();
      }
    });
  }

  Future<void> _preloadNextTrack() async {
    final nextIdx = _getNextIndex();
    if (nextIdx >= tracks.length || nextIdx == _preloadedIndex) return;

    _preloadingNext = true;
    _preloadedIndex = nextIdx;
    final model = tracks[nextIdx];
    debugPrint('[Player] Preloading next: ${model.track.title}');

    AudioSource? source;
    try {
      if (model.track.youtubeUrl != null) {
        source = await YoutubeService.getAudioSourceByUrl(
          model.track.youtubeUrl!,
          model.track.title,
        );
      } else {
        source = await YoutubeService.getAudioSource(
          model.track.title,
          model.track.artists,
        );
      }
    } catch (_) {}

    if (source != null) {
      model.preloadedSource = source;
      debugPrint('[Player] Preloaded: ${model.track.title}');
    }
  }

  void toggleShuffle() {
    shuffleEnabled = !shuffleEnabled;
    debugPrint('[Player] Shuffle: $shuffleEnabled');
    _preloadingNext = false;
    _preloadedIndex = -1;
    notifyListeners();
  }

  void toggleRepeat() {
    switch (repeatMode) {
      case SpoofifyRepeatMode.off:
        repeatMode = SpoofifyRepeatMode.all;
      case SpoofifyRepeatMode.all:
        repeatMode = SpoofifyRepeatMode.one;
      case SpoofifyRepeatMode.one:
        repeatMode = SpoofifyRepeatMode.off;
    }
    debugPrint('[Player] Repeat: $repeatMode');
    notifyListeners();
  }

  void togglePause() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  void seekNext() => _advance();

  void seekPrev() {
    if (shuffleEnabled) {
      _advance();
    } else if (currentIndex > 0) {
      playTrack(currentIndex - 1);
    }
  }

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  Stream<Duration> get positionStream => _player.positionStream;

  void seekTo(Duration pos) => _player.seek(pos);

  void removeHistoryEntry(int index) {
    if (index >= 0 && index < playlistHistory.length) {
      playlistHistory.removeAt(index);
      _saveHistory();
      notifyListeners();
    }
  }

  /// Download current playlist for offline use
  Future<void> downloadCurrentPlaylist() async {
    if (currentPlaylistUrl == null || tracks.isEmpty) return;
    isDownloading = true;
    downloadProgress = 0;
    downloadTotal = tracks.length;
    notifyListeners();

    final trackList = tracks.map((m) => m.track).toList();
    await OfflineService.instance.downloadPlaylist(
      playlistName,
      currentPlaylistUrl!,
      trackList,
      (done, total) {
        downloadProgress = done;
        downloadTotal = total;
        notifyListeners();
      },
    );

    isDownloading = false;
    notifyListeners();
  }

  /// Toggle favorite for current playlist
  Future<void> toggleCurrentFavorite() async {
    if (currentPlaylistUrl == null) return;
    await OfflineService.instance.toggleFavorite(currentPlaylistUrl!);
    notifyListeners();
  }

  bool get isCurrentFavorite {
    if (currentPlaylistUrl == null) return false;
    final saved = OfflineService.instance.getPlaylist(currentPlaylistUrl!);
    return saved?.isFavorite ?? false;
  }

  /// Refresh current playlist from Spotify
  Future<(List<Track> added, List<String> removed)?> refreshCurrentPlaylist() async {
    if (currentPlaylistUrl == null) return null;
    try {
      final result = await OfflineService.instance.refreshPlaylist(currentPlaylistUrl!);
      // Reload the track list
      await loadPlaylist(currentPlaylistUrl!);
      return result;
    } catch (e) {
      debugPrint('[Offline] Refresh error: $e');
      return null;
    }
  }

  /// Try to play a track from offline storage first
  Future<AudioSource?> _getOfflineSource(TrackModel model) async {
    if (currentPlaylistUrl == null) return null;
    final saved = OfflineService.instance.getPlaylist(currentPlaylistUrl!);
    if (saved == null) return null;

    final track = saved.tracks.where((t) =>
        t.title == model.track.title &&
        t.artists == model.track.artists &&
        t.downloaded &&
        t.filePath != null).firstOrNull;
    if (track == null) return null;

    final file = File(track.filePath!);
    if (await file.exists()) {
      return AudioSource.file(track.filePath!);
    }
    return null;
  }

  @override
  void dispose() {
    _player.dispose();
    YoutubeService.dispose();
    super.dispose();
  }
}
