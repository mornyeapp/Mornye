import 'package:flutter/foundation.dart';

enum AutoMixStatus { idle, mixing, crossfading }

final autoMixStatus = ValueNotifier<AutoMixStatus>(AutoMixStatus.idle);

/// Whether AutoMix is decoding and analyzing the songs of its next mix.
final autoMixPreparing = ValueNotifier<bool>(false);
