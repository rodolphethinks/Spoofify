import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../services/spotify_service.dart';
import '../services/youtube_service.dart';

enum TrackState { idle, loading, ready, error }

class TrackModel {
  final Track track;
  TrackState state;
  String? streamUrl;
  String? error;

  TrackModel(this.track) : state = TrackState.idle;
}

class PlayerProvider extends ChangeNotifier {
  final _player = AudioPlayer();

  String playlistName = '';
  List<TrackModel> tracks = [];
  int currentIndex = -1;
  bool isPlaying = false;
  bool isLoadingPlaylist = false;
  String? playlistError;
  // Incremented on every playTrack call so stale requests abort before _loadAndPlay
  int _playSeq = 0;

  PlayerProvider() {
    _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _advance();
      }
      notifyListeners();
    });
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

    model.state = TrackState.loading;
    model.error = null;
    notifyListeners();

    final source = await YoutubeService.getAudioSource(
      model.track.title,
      model.track.artists,
    );

    // A newer playTrack was called while we were fetching — abort.
    if (seq != _playSeq) {
      debugPrint('[Player] Aborted seq=$seq (current=$_playSeq)');
      return;
    }

    if (source == null) {
      debugPrint('[Player] No source found for ${model.track.title}');
      model.state = TrackState.error;
      model.error = 'Not found on YouTube';
      notifyListeners();
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

  void _advance() {
    if (currentIndex < tracks.length - 1) {
      playTrack(currentIndex + 1);
    }
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
    if (currentIndex > 0) playTrack(currentIndex - 1);
  }

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  Stream<Duration> get positionStream => _player.positionStream;

  void seekTo(Duration pos) => _player.seek(pos);

  @override
  void dispose() {
    _player.dispose();
    YoutubeService.dispose();
    super.dispose();
  }
}
