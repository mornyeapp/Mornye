import 'package:flutter/material.dart';

/// Instant passthrough wrapper for app startup without splash delay.
class MornyeAppSplash extends StatelessWidget {
  final Widget child;

  const MornyeAppSplash({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
