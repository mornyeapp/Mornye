import 'package:mornye/models/download_item.dart';

/// Null permits legacy message inference; unknown preserves a typed failure's
/// original message without mistaking provider authentication for a challenge.
DownloadErrorType? downloadErrorTypeFromBackend(String? errorType) =>
    switch (errorType?.trim().toLowerCase()) {
      'not_found' => DownloadErrorType.notFound,
      'rate_limit' => DownloadErrorType.rateLimit,
      'network' => DownloadErrorType.network,
      'permission' => DownloadErrorType.permission,
      'verification_required' => DownloadErrorType.verificationRequired,
      'authentication_error' ||
      'provider_auth_failed' ||
      'request_auth_invalid' ||
      'provider_reauth_required' => DownloadErrorType.unknown,
      _ => null,
    };
