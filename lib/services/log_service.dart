import 'package:flutter/foundation.dart';

enum LogLevel { info, warning, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;

  LogEntry(this.time, this.level, this.message);
}

/// In-memory ring buffer of app logs, viewable from the Settings screen.
/// This is the only way to see failure details on a release build where
/// there's no attached debugger/logcat.
class LogService extends ChangeNotifier {
  LogService._();
  static final LogService instance = LogService._();

  static const _maxEntries = 500;
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void log(String message, {LogLevel? level}) {
    final resolvedLevel = level ?? _inferLevel(message);
    _entries.add(LogEntry(DateTime.now(), resolvedLevel, message));
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    debugPrint(message);
    notifyListeners();
  }

  LogLevel _inferLevel(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('error') || lower.contains('failed')) {
      return LogLevel.error;
    }
    if (lower.contains('warn')) return LogLevel.warning;
    return LogLevel.info;
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String exportAsText() {
    return _entries
        .map((e) =>
            '${e.time.toIso8601String()} [${e.level.name.toUpperCase()}] ${e.message}')
        .join('\n');
  }
}

/// Drop-in replacement for debugPrint that also records to [LogService]
/// so failures are visible in the in-app Settings > Logs screen.
void appLog(String message, {LogLevel? level}) {
  LogService.instance.log(message, level: level);
}
