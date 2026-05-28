import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/lyrics_service.dart';

class LyricsSheet extends StatefulWidget {
  const LyricsSheet({super.key});

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  List<LyricLine>? _lyrics;
  bool _loading = true;
  String? _loadedTrackId;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchLyrics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _trackId(PlayerProvider provider) {
    if (provider.currentIndex < 0) return '';
    final t = provider.tracks[provider.currentIndex].track;
    return '${t.title}|${t.artists}';
  }

  Future<void> _fetchLyrics() async {
    final provider = context.read<PlayerProvider>();
    if (provider.currentIndex < 0) return;
    final track = provider.tracks[provider.currentIndex].track;
    final id = _trackId(provider);

    setState(() {
      _loading = true;
      _loadedTrackId = id;
    });

    // Clean artist string (remove feat, etc for better match)
    final artist = track.artists.split(',').first.trim();
    final lyrics = await LyricsService.getSyncedLyrics(track.title, artist);

    if (!mounted) return;
    setState(() {
      _lyrics = lyrics;
      _loading = false;
    });
  }

  int _getCurrentLineIndex(Duration position) {
    if (_lyrics == null || _lyrics!.isEmpty) return -1;
    // All lines with time zero means plain lyrics (no sync)
    if (_lyrics!.every((l) => l.time == Duration.zero)) return -1;

    int current = -1;
    for (int i = 0; i < _lyrics!.length; i++) {
      if (_lyrics![i].time <= position) {
        current = i;
      } else {
        break;
      }
    }
    return current;
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;
    final offset = (index * 48.0) - 100; // Approximate line height
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlayerProvider>();

    // Reload lyrics if track changed
    if (_trackId(provider) != _loadedTrackId) {
      _fetchLyrics();
    }

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1DB954)),
      );
    }

    if (_lyrics == null || _lyrics!.isEmpty) {
      return const Center(
        child: Text('No lyrics available',
            style: TextStyle(color: Colors.white38, fontSize: 16)),
      );
    }

    final hasSyncedLyrics = !_lyrics!.every((l) => l.time == Duration.zero);

    if (!hasSyncedLyrics) {
      // Plain lyrics - no syncing
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(24),
        itemCount: _lyrics!.length,
        itemBuilder: (_, i) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              _lyrics![i].text.isEmpty ? '♪' : _lyrics![i].text,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          );
        },
      );
    }

    // Synced lyrics
    return StreamBuilder<Duration>(
      stream: provider.positionStream,
      builder: (_, snap) {
        final pos = snap.data ?? Duration.zero;
        final currentLine = _getCurrentLineIndex(pos);

        // Auto-scroll
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (currentLine >= 0) _scrollToLine(currentLine);
        });

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(24),
          itemCount: _lyrics!.length,
          itemBuilder: (_, i) {
            final isActive = i == currentLine;
            final isPast = i < currentLine;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _lyrics![i].text.isEmpty ? '♪' : _lyrics![i].text,
                style: TextStyle(
                  color: isActive
                      ? const Color(0xFF1DB954)
                      : isPast
                          ? Colors.white38
                          : Colors.white70,
                  fontSize: isActive ? 20 : 16,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            );
          },
        );
      },
    );
  }
}
