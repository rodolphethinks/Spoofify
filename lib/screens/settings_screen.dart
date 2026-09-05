import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/log_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  LogLevel? _filter;

  Color _colorFor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return Colors.redAccent;
      case LogLevel.warning:
        return Colors.orangeAccent;
      case LogLevel.info:
        return Colors.white70;
    }
  }

  String _timeLabel(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LogService.instance,
      builder: (context, _) {
        final entries = LogService.instance.entries.reversed
            .where((e) => _filter == null || e.level == _filter)
            .toList();

        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1DB954),
            foregroundColor: Colors.black,
            title: const Text('Settings & Logs',
                style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy all logs',
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: LogService.instance.exportAsText()));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Logs copied to clipboard')),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Clear logs',
                onPressed: () => LogService.instance.clear(),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _FilterChip(
                      label: 'All',
                      selected: _filter == null,
                      onTap: () => setState(() => _filter = null),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Errors',
                      color: Colors.redAccent,
                      selected: _filter == LogLevel.error,
                      onTap: () => setState(() => _filter = LogLevel.error),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Warnings',
                      color: Colors.orangeAccent,
                      selected: _filter == LogLevel.warning,
                      onTap: () => setState(() => _filter = LogLevel.warning),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text('No logs yet',
                            style: TextStyle(color: Colors.white38)),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12),
                                children: [
                                  TextSpan(
                                    text: '${_timeLabel(e.time)}  ',
                                    style:
                                        const TextStyle(color: Colors.white38),
                                  ),
                                  TextSpan(
                                    text: e.message,
                                    style: TextStyle(color: _colorFor(e.level)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color = const Color(0xFF1DB954),
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: color.withValues(alpha: 0.25),
      backgroundColor: const Color(0xFF282828),
      labelStyle: TextStyle(
        color: selected ? color : Colors.white54,
        fontSize: 12,
      ),
      side: BorderSide(color: selected ? color : Colors.transparent),
    );
  }
}
