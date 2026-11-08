class StreamingSource {
  final String url;
  final Map<String, String>? headers;
  final int? durationMs;
  final int? bitrate;
  final String? format;
  final String? service;

  const StreamingSource({
    required this.url,
    this.headers,
    this.durationMs,
    this.bitrate,
    this.format,
    this.service,
  });

  bool get isDirectHttp =>
      url.startsWith('http://') || url.startsWith('https://');
}
