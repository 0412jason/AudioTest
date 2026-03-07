import 'package:flutter/material.dart';
import 'dart:collection';

class WaveformPainter extends CustomPainter {
  final Queue<double> amplitudes;
  final Color color;

  WaveformPainter({required this.amplitudes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final width = size.width;
    final height = size.height;
    final centerY = height / 2;

    final List<double> ampsList = amplitudes.toList();
    final pointCount = ampsList.length;

    const double gapRatio = 0.3; // gap between bars
    final double barWidth = (width / pointCount) * (1 - gapRatio);
    final double step = width / pointCount;
    const double minBarHalfHeight = 1.5;

    for (int i = 0; i < pointCount; i++) {
      final double x = i * step + step / 2;
      final double halfHeight = (ampsList[i] * centerY).clamp(
        minBarHalfHeight,
        centerY,
      );
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centerY),
          width: barWidth,
          height: halfHeight * 2,
        ),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return true;
  }
}
