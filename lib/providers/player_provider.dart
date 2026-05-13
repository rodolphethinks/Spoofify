import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../services/spotify_service.dart';
import '../services/youtube_service.dart';

enum TrackState { idle, loading, ready, error }

class TrackModel {
  final Track track;
  TrackState state;
  String? error;
  AudioSource? preloadedSource;

  TrackModel(this.track) : state = TrackState.idle;
}

class PlayerProvider extends ChangeNotifier {
  final _player = AudioPlayer();
  final _random = Random();

  String playlistName = '';
  List<TrackModel> tracks = [];
  int currentIndex = -1;
  bool isPlaying = false;
  bool isLoadingPlaylist = false;
  String? playlistError;
  bool shuffleEnabled = false;
  List<String> playlistHistory = [];

  int _playSeq = 0;
  bool _preloadingNext = false;
  int _preloadedIndex = -1;
  StreamSubscription<Duration>? _preloadSub;

  PlayerProvider() {
    _loadHistory();
    _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _advance();
      }
      notifyListeners();
    });
  }

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
    notifyListeners();

    try {
      final (name, rawTracks) = await SpotifyService.getTracks(url);
      debugPrint('[Spotify] Got ${rawTracks.length} tracks: $name');
      playlistName = name;
      tracks = rawTracks.map(TrackModel.new).toList();

      // Add to history (remove duplicate first)
      final entry = '$name\n$url';
      playlistHistory.remove(entry);
      playlistHistory.insert(0, entry);
      if (playlistHistory.length > 20) {
        playlistHistory = playlistHistory.sublist(0, 20);
      }
      _saveHistory();
    } catch (e, st) {
      debugPrint('[Spotify] ERROR: $e');
      debugPrint('[Spotify] STACK: $st');
      playlistError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      isLoadingPlaylist = false;
      notifyListeners();
    }
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

    final source = await YoutubeService.getAudioSource(
      model.track.title,
      model.track.artists,
    );

    if (seq != _playSeq) {
      debugPrint('[Player] Aborted seq=$seq (current=$_playSeq)');
      return;
    }

    if (source == null) {
      debugPrint('[Player] No source found for ${model.track.title}');
      model.state = TrackState.error;
      model.error = 'Not found on YouTube';
      notifyListeners();
      _advance();
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
    final next = _getNextIndex();
    if (next < tracks.length) {
      playTrack(next);
    }
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

    final source = await YoutubeService.getAudioSource(
      model.track.title,
      model.track.artists,
    );

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

  @override
  void dispose() {
    _player.dispose();
    YoutubeService.dispose();
    super.dispose();
  }
}
