import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';

void main() {
  for (final circular in [false, true]) {
    testWidgets('${circular ? 'circular' : 'linear'} wave only ticks while '
        'it is drawn wavy', (tester) async {
      final progress = ValueNotifier<double?>(null);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 48,
                child: ValueListenableBuilder(
                  valueListenable: progress,
                  builder: (context, value, _) => circular
                      ? AppProgressIndicator.circular(value: value)
                      : AppProgressIndicator.linear(value: value),
                ),
              ),
            ),
          ),
        ),
      );

      Future<bool> ticks(double? value) async {
        progress.value = value;
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        return tester.binding.hasScheduledFrame;
      }

      for (final value in [0.0, 0.05, 0.1, 0.95, 0.99, 1.0]) {
        expect(await ticks(value), isFalse, reason: 'value $value');
      }
      for (final value in [null, 0.11, 0.5, 0.94]) {
        expect(await ticks(value), isTrue, reason: 'value $value');
      }
      expect(await ticks(0.05), isFalse);
    });
  }
}
