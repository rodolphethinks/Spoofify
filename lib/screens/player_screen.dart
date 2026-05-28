import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import 'lyrics_sheet.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<PlayerProvider>();
      if (provider.currentIndex < 0 && provider.tracks.isNotEmpty) {
        provider.playTrack(0);
      }
    });
  }

  void _showQueue(BuildContext context) {
    final provider = context.read<PlayerProvider>();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: provider,
        child: const _QueueSheet(),
      ),
    );
  }

  void _showLyrics(BuildContext context) {
    final provider = context.read<PlayerProvider>();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: provider,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: const LyricsSheet(),
        ),
      ),
    );
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
        actions: [
          IconButton(
            icon: const Icon(Icons.lyrics),
            onPressed: () => _showLyrics(context),
          ),
          IconButton(
            icon: Icon(
              provider.isCurrentFavorite
                  ? Icons.favorite
                  : Icons.favorite_border,
            ),
            onPressed: () async {
              // If not already saved, download first
              if (!provider.isCurrentFavorite) {
                await provider.downloadCurrentPlaylist();
              }
              await provider.toggleCurrentFavorite();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final result = await provider.refreshCurrentPlaylist();
              if (!context.mounted) return;
              if (result != null) {
                final (added, removed) = result;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      '+${added.length} new, -${removed.length} removed'),
                ));
              }
            },
          ),
          if (provider.queue.isNotEmpty)
            Badge(
              label: Text('${provider.queue.length}'),
              child: IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: () => _showQueue(context),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.queue_music),
              onPressed: () => _showQueue(context),
            ),
        ],
      ),
      body: Column(
        children: [
          // Download progress bar
          if (provider.isDownloading)
            LinearProgressIndicator(
              value: provider.downloadTotal > 0
                  ? provider.downloadProgress / provider.downloadTotal
                  : null,
              backgroundColor: Colors.white12,
              color: const Color(0xFF1DB954),
              minHeight: 3,
            ),
          Expanded(
            child: ListView.builder(
              itemCount: provider.tracks.length,
              itemBuilder: (context, i) {
                final model = provider.tracks[i];
                final isCurrent = i == provider.currentIndex;

                return Dismissible(
                  key: ValueKey('${model.track.title}_$i'),
                  direction: DismissDirection.startToEnd,
                  confirmDismiss: (_) async {
                    provider.addToQueue(model.track);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            '"${model.track.title}" added to queue'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                    return false; // Don't actually dismiss
                  },
                  background: Container(
                    color: const Color(0xFF1DB954),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 20),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.playlist_add, color: Colors.black),
                        SizedBox(width: 8),
                        Text('Play next',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  child: ListTile(
                    onTap: () => provider.playTrack(i),
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
                          TrackState.error => Tooltip(
                              message: model.error ?? 'Unknown error',
                              child: const Icon(Icons.error_outline,
                                  color: Colors.redAccent, size: 20)),
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
                        color:
                            isCurrent ? const Color(0xFF1DB954) : Colors.white,
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: model.state == TrackState.error && model.error != null
                        ? Text(
                            model.error!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                          )
                        : model.track.artists.isNotEmpty
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
                  ),
                );
              },
            ),
          ),
          if (provider.currentIndex >= 0) _PlayerBar(provider: provider),
        ],
      ),
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlayerProvider>();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Queue',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              if (provider.queue.isNotEmpty)
                TextButton(
                  onPressed: provider.clearQueue,
                  child: const Text('Clear all',
                      style: TextStyle(color: Color(0xFF1DB954))),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (provider.queue.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('Queue is empty\nSwipe right on a song to add it',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38)),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: provider.queue.length,
                itemBuilder: (context, i) {
                  final track = provider.queue[i];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${i + 1}',
                        style: const TextStyle(color: Colors.white54)),
                    title: Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text(track.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white38)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white38, size: 18),
                      onPressed: () => provider.removeFromQueue(i),
                    ),
                  );
                },
              ),
            ),
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
                          provider.seekTo(Duration(
                              milliseconds:
                                  (v * dur.inMilliseconds).round()));
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(pos),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                        Text(_formatDuration(dur),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
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
                IconButton(
                  onPressed: provider.toggleRepeat,
                  icon: Icon(
                    provider.repeatMode == SpoofifyRepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: provider.repeatMode == SpoofifyRepeatMode.off
                        ? Colors.white38
                        : const Color(0xFF1DB954),
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
