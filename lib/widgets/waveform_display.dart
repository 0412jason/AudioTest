import 'package:flutter/material.dart';
import 'dart:collection';
import 'package:audiotest/widgets/waveform_painter.dart';

class WaveformDisplay extends StatelessWidget {
  final Queue<double> amplitudes;
  final Color color;
  final double height;

  const WaveformDisplay({
    super.key,
    required this.amplitudes,
    required this.color,
    this.height = 60.0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          painter: WaveformPainter(amplitudes: amplitudes, color: color),
        ),
      ),
    );
  }
}
