import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/spotify_service.dart';
import '../services/youtube_service.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  bool _isSearching = false;
  List<SpotifySearchResult> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _tryPasteFromClipboard();
  }

  Future<void> _tryPasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.contains('open.spotify.com')) {
      setState(() => _controller.text = text.trim());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (SpotifyService.isSpotifyUrl(text)) {
      await _loadPlaylistUrl(text);
    } else {
      await _performSearch(text);
    }
  }

  Future<void> _loadPlaylistUrl(String url) async {
    final provider = context.read<PlayerProvider>();
    await provider.loadPlaylist(url);
    if (!mounted) return;
    if (provider.playlistError == null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PlayerScreen()),
      );
    }
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isSearching = true;
      _searchResults = [];
    });
    try {
      final results = await YoutubeService.search(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search failed: $e')),
      );
    }
  }

  void _playSearchResult(SpotifySearchResult r) {
    if (SpotifyService.isSpotifyUrl(r.url)) {
      _loadPlaylistUrl(r.url);
      return;
    }
    // YouTube result — play directly as a single track
    final provider = context.read<PlayerProvider>();
    // Parse title: remove common suffixes like "(Official Video)" etc.
    var title = r.name;
    var artist = r.subtitle;
    // If title contains " - ", split into artist - title
    if (title.contains(' - ')) {
      final parts = title.split(' - ');
      artist = parts[0].trim();
      title = parts.sublist(1).join(' - ').trim();
    }
    // Remove common YouTube suffixes
    title = title
        .replaceAll(RegExp(r'\s*\(Official.*?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\[Official.*?\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\(Lyrics?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\[Lyrics?\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\(Audio\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\|.*$'), '')
        .trim();
    provider.playSearchResults(
      [Track(title: title, artists: artist, youtubeUrl: r.url)],
      'Search',
      0,
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlayerProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Text(
                'Spoofify',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1DB954),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ad-free music from Spotify playlists',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 32),

              // URL/Search input
              TextField(
                controller: _controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Paste Spotify link or search...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF282828),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.search, color: Colors.white38),
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.white38),
                          onPressed: () {
                            _controller.clear();
                            setState(() => _searchResults = []);
                          },
                        )
                      : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),

              if (provider.playlistError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    provider.playlistError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),

              FilledButton(
                onPressed: (provider.isLoadingPlaylist || _isSearching)
                    ? null
                    : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(50),
                  ),
                ),
                child: (provider.isLoadingPlaylist || _isSearching)
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Go',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),

              const SizedBox(height: 16),

              // Search results, favorites, or history
              Expanded(
                child: _searchResults.isNotEmpty
                    ? _buildSearchResults()
                    : _buildFavoritesAndHistory(provider),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Search results',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _searchResults = []),
              child: const Text('Clear',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _searchResults.length,
            itemBuilder: (context, i) {
              final r = _searchResults[i];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  r.type == 'playlist'
                      ? Icons.queue_music
                      : r.type == 'album'
                          ? Icons.album
                          : Icons.music_note,
                  color: const Color(0xFF1DB954),
                  size: 22,
                ),
                title: Text(r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(
                  '${r.type[0].toUpperCase()}${r.type.substring(1)}${r.subtitle.isNotEmpty ? ' · ${r.subtitle}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () => _playSearchResult(r),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFavoritesAndHistory(PlayerProvider provider) {
    return ListView(
      children: [
        // Favorites section
        if (provider.favorites.isNotEmpty) ...[
          const Text('Favorites',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...provider.favorites.map((p) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.favorite,
                    color: Color(0xFF1DB954), size: 20),
                title: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(
                    '${p.downloadedCount}/${p.tracks.length} downloaded',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
                onTap: () => _loadPlaylistUrl(p.url),
              )),
          const SizedBox(height: 16),
        ],
        // History section
        if (provider.playlistHistory.isNotEmpty) ...[
          const Text('Recent playlists',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 8),
          ...List.generate(provider.playlistHistory.length, (i) {
            final entry = provider.playlistHistory[i];
            final parts = entry.split('\n');
            final name = parts[0];
            final url = parts.length > 1 ? parts[1] : '';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music,
                  color: Color(0xFF1DB954), size: 20),
              title: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              trailing: IconButton(
                icon: const Icon(Icons.close,
                    color: Colors.white38, size: 16),
                onPressed: () => provider.removeHistoryEntry(i),
              ),
              onTap: () => _loadPlaylistUrl(url),
            );
          }),
        ],
      ],
    );
  }
}
