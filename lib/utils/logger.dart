import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/native_log_source.dart';

const int _maxLogMessageLength = 500;
const int _maxBufferedLogMessageLength = 4000;
const String _redactedValue = '[REDACTED]';

final RegExp _authorizationBearerPattern = RegExp(
  r'\bAuthorization\b\s*[:=]\s*Bearer\s+[A-Za-z0-9._~+/\-]+=*',
  caseSensitive: false,
);

final RegExp _genericSensitiveKeyValuePattern = RegExp(
  r'("?(?:access[_\s-]?token|refresh[_\s-]?token|id[_\s-]?token|client[_\s-]?secret|authorization|password|api[_\s-]?key|session[_\s-]?secret|decryption[_\s-]?key|cookie|set-cookie)"?)(\s*[:=]\s*)("(?:\\.|[^"\\])*"|[^\s,;}\]]+)',
  caseSensitive: false,
);

final RegExp _sensitiveQueryPattern = RegExp(
  r'([?&](?:access_token|refresh_token|id_token|token|client_secret|api_key|apikey|password|code|grant|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|awsaccesskeyid|googleaccessid|policy|key-pair-id)=)[^&\s]+',
  caseSensitive: false,
);

final RegExp _bearerTokenPattern = RegExp(
  r'\bBearer\s+[A-Za-z0-9._~+/\-]+=*',
  caseSensitive: false,
);

final RegExp _decryptionKeyFlagPattern = RegExp(
  r'(-decryption_key\s+)[^\s]+',
  caseSensitive: false,
);

String _truncateLogText(String value, {int maxLength = _maxLogMessageLength}) {
  if (value.length <= maxLength) {
    return value;
  }
  return '${value.substring(0, maxLength)}...[truncated]';
}

String _redactSensitiveText(String value) {
  var redacted = value;

  redacted = redacted.replaceAllMapped(_authorizationBearerPattern, (_) {
    return 'Authorization: Bearer $_redactedValue';
  });

  redacted = redacted.replaceAllMapped(_genericSensitiveKeyValuePattern, (
    match,
  ) {
    final key = match.group(1) ?? '';
    final delimiter = match.group(2) ?? '=';
    return '$key$delimiter$_redactedValue';
  });

  redacted = redacted.replaceAllMapped(_sensitiveQueryPattern, (match) {
    final prefix = match.group(1) ?? '';
    return '$prefix$_redactedValue';
  });

  redacted = redacted.replaceAllMapped(_bearerTokenPattern, (_) {
    return 'Bearer $_redactedValue';
  });

  redacted = redacted.replaceAllMapped(_decryptionKeyFlagPattern, (match) {
    return '${match.group(1) ?? '-decryption_key '}$_redactedValue';
  });

  return redacted;
}

/// Crash reports use the same secret filtering as the ordinary log export.
String redactDiagnosticText(String value) => _redactSensitiveText(value);

class LogEntry {
  final DateTime timestamp;
  final String level;
  final String tag;
  final String message;
  final String? error;
  final bool isFromNative;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.isFromNative = false,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get previewMessage => _truncateLogText(message);

  String? get previewError => error == null ? null : _truncateLogText(error!);

  @override
  String toString() {
    final errorPart = error != null ? ' | $error' : '';
    final nativePart = isFromNative ? ' [Native]' : '';
    return '[$formattedTime] [$level]$nativePart [$tag] $message$errorPart';
  }
}

String formatLogEntries(Iterable<LogEntry> entries) {
  return entries.map((entry) => entry.toString()).join('\n');
}

class LogBuffer extends ChangeNotifier {
  static final LogBuffer _instance = LogBuffer._internal();
  factory LogBuffer() => _instance;
  LogBuffer._internal();

  static const int maxEntries = 500;
  static const _nativeLogs = NativeLogSource();
  static const Duration _nativeLogPollingInterval = Duration(milliseconds: 800);
  final Queue<LogEntry> _entries = Queue<LogEntry>();
  Timer? _nativeLogTimer;
  int _lastNativeLogIndex = 0;
  bool _isFetchingNativeLogs = false;
  int _nativeLogGeneration = 0;
  Future<void>? _pendingNativeLogClear;

  static bool _loggingEnabled = false;

  /// Receives every entry the buffer keeps, already redacted and filtered.
  /// Desktop writes these to rotating log files.
  static void Function(LogEntry entry)? fileSink;

  static bool get loggingEnabled => _loggingEnabled;
  static set loggingEnabled(bool value) {
    _loggingEnabled = value;
    _nativeLogs.setLoggingEnabled(value).catchError((_) {});
  }

  List<LogEntry> get entries => _entries.toList();
  int get length => _entries.length;

  void add(LogEntry entry) {
    if (_append(entry)) notifyListeners();
  }

  /// A native poll is one UI update, even when it contains hundreds of logs.
  void addAll(Iterable<LogEntry> entries) {
    var changed = false;
    for (final entry in entries) {
      changed = _append(entry) || changed;
    }
    if (changed) notifyListeners();
  }

  bool _append(LogEntry entry) {
    if (!_loggingEnabled && entry.level != 'ERROR' && entry.level != 'FATAL') {
      return false;
    }

    final sanitizedMessage = _truncateLogText(
      _redactSensitiveText(entry.message),
      maxLength: _maxBufferedLogMessageLength,
    );
    final sanitizedError = entry.error != null
        ? _truncateLogText(
            _redactSensitiveText(entry.error!),
            maxLength: _maxBufferedLogMessageLength,
          )
        : null;
    final sanitizedEntry =
        (sanitizedMessage == entry.message && sanitizedError == entry.error)
        ? entry
        : LogEntry(
            timestamp: entry.timestamp,
            level: entry.level,
            tag: entry.tag,
            message: sanitizedMessage,
            error: sanitizedError,
            isFromNative: entry.isFromNative,
          );

    if (_entries.length >= maxEntries) {
      _entries.removeFirst();
    }
    _entries.add(sanitizedEntry);
    fileSink?.call(sanitizedEntry);
    return true;
  }

  void startNativeLogPolling() {
    _nativeLogTimer?.cancel();
    _nativeLogGeneration++;
    _nativeLogTimer = Timer.periodic(_nativeLogPollingInterval, (_) async {
      if (_isFetchingNativeLogs) return;
      _isFetchingNativeLogs = true;
      try {
        await _fetchNativeLogs(_nativeLogGeneration);
      } finally {
        _isFetchingNativeLogs = false;
      }
    });
  }

  void stopNativeLogPolling() {
    _nativeLogTimer?.cancel();
    _nativeLogTimer = null;
    _nativeLogGeneration++;
    // The stopped poll still owns the in-flight slot until its call completes.
  }

  Future<void> _fetchNativeLogs(int generation) async {
    try {
      final clearing = _pendingNativeLogClear;
      if (clearing != null) await clearing;
      if (generation != _nativeLogGeneration) return;
      final result = await _nativeLogs.getSince(_lastNativeLogIndex);
      if (generation != _nativeLogGeneration) return;
      final logs = result['logs'] as List<dynamic>? ?? [];
      final nextIndex = result['next_index'] as int? ?? _lastNativeLogIndex;
      final keepNonErrorLogs = _loggingEnabled;
      final entries = <LogEntry>[];

      for (final log in logs.whereType<Map<Object?, Object?>>()) {
        final logMap = Map<String, dynamic>.from(log);
        final level = logMap['level'] as String? ?? 'INFO';
        if (!keepNonErrorLogs && level != 'ERROR' && level != 'FATAL') {
          continue;
        }

        final timestamp = logMap['timestamp'] as String? ?? '';
        final tag = logMap['tag'] as String? ?? 'Native';
        final message = logMap['message'] as String? ?? '';

        DateTime parsedTime = DateTime.now();
        if (timestamp.isNotEmpty) {
          try {
            final parts = timestamp.split(':');
            if (parts.length >= 3) {
              final secParts = parts[2].split('.');
              parsedTime = DateTime(
                parsedTime.year,
                parsedTime.month,
                parsedTime.day,
                int.parse(parts[0]),
                int.parse(parts[1]),
                int.parse(secParts[0]),
                secParts.length > 1 ? int.parse(secParts[1]) : 0,
              );
            }
          } catch (_) {}
        }

        entries.add(
          LogEntry(
            timestamp: parsedTime,
            level: level,
            tag: tag,
            message: message,
            isFromNative: true,
          ),
        );
      }

      addAll(entries);
      if (generation == _nativeLogGeneration) _lastNativeLogIndex = nextIndex;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to fetch native backend logs: $e');
      }
    }
  }

  void clear() {
    _entries.clear();
    _lastNativeLogIndex = 0;
    _nativeLogGeneration++;
    late final Future<void> clearing;
    clearing =
        (_pendingNativeLogClear?.then((_) => _nativeLogs.clear()) ??
                _nativeLogs.clear())
            .catchError((_) {})
            .whenComplete(() {
              if (identical(_pendingNativeLogClear, clearing)) {
                _pendingNativeLogClear = null;
              }
            });
    _pendingNativeLogClear = clearing;
    notifyListeners();
  }

  String export() {
    final buffer = StringBuffer();
    buffer.writeln('${AppInfo.appName} Log Export');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Entries: ${_entries.length}');
    buffer.writeln('=' * 60);
    buffer.writeln();
    for (final entry in _entries) {
      buffer.writeln(entry.toString());
    }
    return buffer.toString();
  }

  Future<String> exportWithDeviceInfo() async {
    final buffer = StringBuffer();

    buffer.writeln('=' * 60);
    buffer.writeln('${AppInfo.appName.toUpperCase()} LOG EXPORT');
    buffer.writeln('=' * 60);
    buffer.writeln();

    buffer.writeln('--- App Information ---');
    buffer.writeln(
      'App Version: ${AppInfo.version} (Build ${AppInfo.buildNumber})',
    );
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln();

    buffer.writeln('--- Device Information ---');
    try {
      final deviceInfo = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        buffer.writeln('Platform: Android');
        buffer.writeln('Device: ${android.manufacturer} ${android.model}');
        buffer.writeln('Brand: ${android.brand}');
        buffer.writeln(
          'Android Version: ${android.version.release} (SDK ${android.version.sdkInt})',
        );
        buffer.writeln('Build ID: ${android.id}');
        if (android.version.securityPatch != null &&
            android.version.securityPatch!.isNotEmpty) {
          buffer.writeln('Security Patch: ${android.version.securityPatch}');
        }
        buffer.writeln('Hardware: ${android.hardware}');
        buffer.writeln('Product: ${android.product}');
        buffer.writeln('Supported ABIs: ${android.supportedAbis.join(', ')}');
        buffer.writeln('Is Physical Device: ${android.isPhysicalDevice}');
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        buffer.writeln('Platform: iOS');
        buffer.writeln('Device: ${ios.utsname.machine}');
        buffer.writeln('Model: ${ios.model}');
        buffer.writeln('System Name: ${ios.systemName}');
        buffer.writeln('System Version: ${ios.systemVersion}');
        buffer.writeln('Device Name: ${ios.name}');
        buffer.writeln('Is Physical Device: ${ios.isPhysicalDevice}');
      } else if (Platform.isMacOS) {
        final macos = await deviceInfo.macOsInfo;
        buffer.writeln('Platform: macOS');
        buffer.writeln('Model: ${macos.model}');
        buffer.writeln(
          'OS Version: ${macos.osRelease} (Kernel ${macos.kernelVersion})',
        );
        buffer.writeln('Architecture: ${macos.arch}');
        buffer.writeln('Memory: ${macos.memorySize ~/ (1024 * 1024)} MB');
      } else if (Platform.isWindows) {
        final windows = await deviceInfo.windowsInfo;
        buffer.writeln('Platform: Windows');
        buffer.writeln('Product: ${windows.productName}');
        buffer.writeln(
          'Version: ${windows.displayVersion} (Build ${windows.buildNumber})',
        );
        buffer.writeln('Memory: ${windows.systemMemoryInMegabytes} MB');
      } else if (Platform.isLinux) {
        final linux = await deviceInfo.linuxInfo;
        buffer.writeln('Platform: Linux');
        buffer.writeln('Distribution: ${linux.prettyName}');
        buffer.writeln('Kernel: ${Platform.operatingSystemVersion}');
      }
    } catch (e) {
      buffer.writeln('Failed to get device info: $e');
    }
    buffer.writeln();

    buffer.writeln('--- Log Summary ---');
    buffer.writeln('Total Entries: ${_entries.length}');

    int errorCount = 0;
    int warnCount = 0;
    int infoCount = 0;
    int debugCount = 0;
    int nativeCount = 0;

    for (final entry in _entries) {
      switch (entry.level) {
        case 'ERROR' || 'FATAL':
          errorCount++;
        case 'WARN':
          warnCount++;
        case 'INFO':
          infoCount++;
        case 'DEBUG':
          debugCount++;
      }
      if (entry.isFromNative) nativeCount++;
    }

    buffer.writeln('Errors: $errorCount');
    buffer.writeln('Warnings: $warnCount');
    buffer.writeln('Info: $infoCount');
    buffer.writeln('Debug: $debugCount');
    buffer.writeln('From Native Backend: $nativeCount');
    buffer.writeln();

    buffer.writeln('=' * 60);
    buffer.writeln('LOG ENTRIES');
    buffer.writeln('=' * 60);
    buffer.writeln();

    for (final entry in _entries) {
      buffer.writeln(entry.toString());
    }

    return buffer.toString();
  }

  List<LogEntry> filter({String? level, String? tag, String? search}) {
    final tagLower = tag?.toLowerCase();
    final searchLower = search?.toLowerCase();

    return _entries.where((entry) {
      if (level != null && level != 'ALL' && entry.level != level) {
        return false;
      }
      if (tagLower != null && !entry.tag.toLowerCase().contains(tagLower)) {
        return false;
      }
      if (searchLower != null && searchLower.isNotEmpty) {
        return entry.message.toLowerCase().contains(searchLower) ||
            entry.tag.toLowerCase().contains(searchLower) ||
            (entry.error?.toLowerCase().contains(searchLower) ?? false);
      }
      return true;
    }).toList();
  }
}

class BufferedOutput extends LogOutput {
  final String tag;

  BufferedOutput(this.tag);

  @override
  void output(OutputEvent event) {
    if (kDebugMode &&
        (LogBuffer.loggingEnabled ||
            event.level == Level.warning ||
            event.level == Level.error ||
            event.level == Level.fatal)) {
      for (final line in event.lines) {
        debugPrint(_truncateLogText(_redactSensitiveText(line)));
      }
    }

    final level = _levelToString(event.level);
    final message = _redactSensitiveText(event.lines.join('\n'));

    LogBuffer().add(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        tag: tag,
        message: message,
      ),
    );
  }

  String _levelToString(Level level) => switch (level) {
    Level.debug => 'DEBUG',
    Level.info => 'INFO',
    Level.warning => 'WARN',
    Level.error => 'ERROR',
    Level.fatal => 'FATAL',
    _ => 'LOG',
  };
}

class AppLogger {
  final String _tag;
  late final Logger? _logger;

  AppLogger(this._tag) {
    if (kDebugMode) {
      _logger = Logger(
        printer: SimplePrinter(printTime: false, colors: false),
        output: BufferedOutput(_tag),
        level: Level.debug,
      );
    } else {
      _logger = null;
    }
  }

  void _addToBuffer(String level, String message, {String? error}) {
    if (!LogBuffer.loggingEnabled && level != 'ERROR' && level != 'FATAL') {
      return;
    }

    LogBuffer().add(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        tag: _tag,
        message: message,
        error: error,
      ),
    );
  }

  void d(String message) {
    if (kDebugMode) {
      _logger?.d(message);
    } else {
      _addToBuffer('DEBUG', message);
    }
  }

  void i(String message) {
    if (kDebugMode) {
      _logger?.i(message);
    } else {
      _addToBuffer('INFO', message);
    }
  }

  void w(String message) {
    if (kDebugMode) {
      _logger?.w(message);
    } else {
      _addToBuffer('WARN', message);
    }
  }

  void e(String message, [Object? error, StackTrace? stackTrace]) {
    if (error != null) {
      _addToBuffer('ERROR', message, error: error.toString());
      if (kDebugMode) {
        debugPrint(
          '[$_tag] ERROR: ${_truncateLogText(_redactSensitiveText(message))} | ${_truncateLogText(_redactSensitiveText(error.toString()))}',
        );
        if (stackTrace != null) {
          debugPrint(stackTrace.toString());
        }
      }
    } else {
      if (kDebugMode) {
        _logger?.e(message);
      } else {
        _addToBuffer('ERROR', message);
      }
    }
  }
}
