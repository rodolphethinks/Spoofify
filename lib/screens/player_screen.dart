import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-play first track when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<PlayerProvider>();
      if (provider.currentIndex < 0 && provider.tracks.isNotEmpty) {
        provider.playTrack(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlayerProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1DB954),
        foregroundColor: Colors.black,
        title: Text(
          provider.playlistName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          // Track list
          Expanded(
            child: ListView.builder(
              itemCount: provider.tracks.length,
              itemBuilder: (context, i) {
                final model = provider.tracks[i];
                final isCurrent = i == provider.currentIndex;

                return ListTile(
                  onTap: () => context.read<PlayerProvider>().playTrack(i),
                  tileColor: isCurrent ? const Color(0xFF282828) : null,
                  leading: SizedBox(
                    width: 32,
                    child: Center(
                      child: switch (model.state) {
                        TrackState.loading => const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1DB954),
                            ),
                          ),
                        TrackState.error => const Icon(Icons.error_outline,
                            color: Colors.redAccent, size: 20),
                        _ => Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: isCurrent
                                  ? const Color(0xFF1DB954)
                                  : Colors.white54,
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                      },
                    ),
                  ),
                  title: Text(
                    model.track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFF1DB954) : Colors.white,
                      fontWeight:
                          isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: model.track.artists.isNotEmpty
                      ? Text(
                          model.track.artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54),
                        )
                      : null,
                  trailing: isCurrent && provider.isPlaying
                      ? const Icon(Icons.volume_up,
                          color: Color(0xFF1DB954), size: 18)
                      : null,
                );
              },
            ),
          ),

          // Player bar
          if (provider.currentIndex >= 0) _PlayerBar(provider: provider),
        ],
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  final PlayerProvider provider;
  const _PlayerBar({required this.provider});

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final model = provider.tracks[provider.currentIndex];

    return Container(
      color: const Color(0xFF181818),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seek bar
          StreamBuilder<Duration>(
            stream: provider.positionStream,
            builder: (_, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = provider.duration ?? Duration.zero;
              final progress = dur.inMilliseconds > 0
                  ? pos.inMilliseconds / dur.inMilliseconds
                  : 0.0;
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: const Color(0xFF1DB954),
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white12,
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (v) {
                        if (dur.inMilliseconds > 0) {
                          provider.seekTo(
                              Duration(milliseconds: (v * dur.inMilliseconds).round()));
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(pos),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                        Text(
                          _formatDuration(dur),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          // Track info + controls
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                // Track info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        model.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                      ),
                      if (model.track.artists.isNotEmpty)
                        Text(
                          model.track.artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                    ],
                  ),
                ),

                // Controls
                IconButton(
                  onPressed: provider.toggleShuffle,
                  icon: Icon(Icons.shuffle,
                      color: provider.shuffleEnabled
                          ? const Color(0xFF1DB954)
                          : Colors.white38,
                      size: 22),
                ),
                IconButton(
                  onPressed: provider.seekPrev,
                  icon: const Icon(Icons.skip_previous,
                      color: Colors.white, size: 28),
                ),
                IconButton(
                  onPressed: model.state == TrackState.loading
                      ? null
                      : provider.togglePause,
                  icon: Icon(
                    provider.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                IconButton(
                  onPressed: provider.seekNext,
                  icon: const Icon(Icons.skip_next,
                      color: Colors.white, size: 28),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
