import 'dart:async';
import 'dart:io';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/audio_file_open_service.dart';

final _log = AppLogger('ShareIntent');

class ShareIntentService {
  static final ShareIntentService _instance = ShareIntentService._internal();
  factory ShareIntentService() => _instance;
  ShareIntentService._internal();

  static final RegExp _spotifyUriPattern = RegExp(
    r'spotify:(track|album|playlist|artist):[a-zA-Z0-9]+',
  );
  static final RegExp _genericHttpUrlPattern = RegExp(
    "https?://[^\\s<>\\\"']+",
    caseSensitive: false,
  );

  final _sharedUrlController = StreamController<String>.broadcast();
  StreamSubscription<List<SharedMediaFile>>? _mediaSubscription;
  bool _initialized = false;
  String? _pendingUrl;

  Stream<String> get sharedUrlStream => _sharedUrlController.stream;

  String? consumePendingUrl() {
    final url = _pendingUrl;
    _pendingUrl = null;
    return url;
  }

  void injectUrl(String url) {
    if (url.isEmpty) return;
    _pendingUrl = url;
    _sharedUrlController.add(url);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid && !Platform.isIOS) {
      _log.i('Share intent is not supported on this platform');
      return;
    }

    _mediaSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleSharedMedia,
      onError: (Object err) => _log.e('Error: $err'),
    );

    final initialMedia = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initialMedia.isNotEmpty) {
      _handleSharedMedia(initialMedia, isInitial: true);
      ReceiveSharingIntent.instance.reset();
    }
  }

  void _handleSharedMedia(
    List<SharedMediaFile> files, {
    bool isInitial = false,
  }) {
    final audio = [
      for (final file in files)
        if (file.type == SharedMediaType.file &&
            OpenAudioFile.parse(file.path)?.isAudio == true)
          file.path,
    ];
    if (audio.isNotEmpty) {
      AudioFileOpenService.instance.receive(audio);
      return;
    }
    for (final file in files) {
      final textsToCheck = [file.path, if (file.message != null) file.message!];

      for (final textToCheck in textsToCheck) {
        final url = _extractMusicUrl(textToCheck);
        if (url != null) {
          _log.i('Received supported music link (initial=$isInitial)');
          if (isInitial) {
            _pendingUrl = url;
          }
          _sharedUrlController.add(url);
          return;
        }
      }
    }
  }

  String? _extractMusicUrl(String text) {
    if (text.isEmpty) return null;

    final uriMatch = _spotifyUriPattern.firstMatch(text);
    if (uriMatch != null) {
      return uriMatch.group(0);
    }

    // Keep share parsing generic and let manifest-based URL handlers decide
    // which installed extension can handle the incoming link.
    for (final match in _genericHttpUrlPattern.allMatches(text)) {
      final rawUrl = match.group(0);
      if (rawUrl == null || rawUrl.isEmpty) {
        continue;
      }

      final sanitizedUrl = rawUrl.replaceFirst(RegExp(r'[.,;:!?)\]}]+$'), '');
      if (sanitizedUrl.isNotEmpty) {
        return sanitizedUrl;
      }
    }

    return null;
  }

  void dispose() {
    _mediaSubscription?.cancel();
    _sharedUrlController.close();
  }
}
