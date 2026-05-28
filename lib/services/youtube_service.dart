import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

class YoutubeService {
  static const _channel = MethodChannel('com.spoofify/newpipe');

  // Serialize requests so downloads don't race
  static Future<void> _lock = Future.value();

  static Future<AudioSource?> getAudioSource(
      String title, String artists) async {
    final completer = Completer<void>();
    final previousLock = _lock;
    _lock = completer.future;
    await previousLock;
    try {
      return await _fetchAudioSource(title, artists);
    } finally {
      completer.complete();
    }
  }

  /// Download to a specific permanent directory and return the file path.
  static Future<String?> getAudioSourceToDir(
      String title, String artists, String dir) async {
    final completer = Completer<void>();
    final previousLock = _lock;
    _lock = completer.future;
    await previousLock;
    try {
      return await _downloadToDir(title, artists, dir);
    } finally {
      completer.complete();
    }
  }

  static Future<AudioSource?> _fetchAudioSource(
      String title, String artists) async {
    debugPrint('[YT] Fetching: $artists - $title');
    try {
      final cacheDir = (await getTemporaryDirectory()).path;
      final filePath = await _channel.invokeMethod<String>('getAudioFile', {
        'title': title,
        'artist': artists,
        'cacheDir': cacheDir,
      });
      if (filePath == null) {
        debugPrint('[YT] No audio found');
        return null;
      }
      debugPrint('[YT] Got file: $filePath');
      return AudioSource.file(filePath);
    } on PlatformException catch (e) {
      debugPrint('[YT] Platform error: ${e.code} - ${e.message}');
      throw Exception('YouTube: ${e.message ?? e.code}');
    } catch (e) {
      debugPrint('[YT] Error: $e');
      rethrow;
    }
  }

  static Future<String?> _downloadToDir(
      String title, String artists, String dir) async {
    debugPrint('[YT] Downloading to dir: $artists - $title');
    try {
      final filePath = await _channel.invokeMethod<String>('getAudioFile', {
        'title': title,
        'artist': artists,
        'cacheDir': dir,
      });
      if (filePath == null) {
        debugPrint('[YT] No audio found');
        return null;
      }
      debugPrint('[YT] Downloaded: $filePath');
      return filePath;
    } on PlatformException catch (e) {
      debugPrint('[YT] Platform error: ${e.code} - ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[YT] Error: $e');
      return null;
    }
  }

  static void dispose() {}
}
