import 'dart:math';

class ScoredEpoch {
  final int startMs;
  final int endMs;
  final double activity;
  final double meanHr;
  final bool isSleep;

  const ScoredEpoch({
    required this.startMs,
    required this.endMs,
    required this.activity,
    required this.meanHr,
    required this.isSleep,
  });
}

class _EpochFeature {
  final int startMs;
  final int endMs;
  final double activity;
  final double meanHr;

  const _EpochFeature({
    required this.startMs,
    required this.endMs,
    required this.activity,
    required this.meanHr,
  });
}

class SleepScorer {
  static List<ScoredEpoch> scoreRows(
      List<Map<String, Object?>> rows, {
        int epochSeconds = 60,
      }) {
    if (rows.isEmpty) return [];

    final sorted = List<Map<String, Object?>>.from(rows)
      ..sort(
            (a, b) => (a['timestamp_ms'] as int).compareTo(b['timestamp_ms'] as int),
      );

    final epochs = _buildEpochs(sorted, epochSeconds: epochSeconds);
    if (epochs.isEmpty) return [];

    final out = <ScoredEpoch>[];
    for (int i = 0; i < epochs.length; i++) {
      final isSleep = _classifyEpochProxy(epochs, i);
      out.add(
        ScoredEpoch(
          startMs: epochs[i].startMs,
          endMs: epochs[i].endMs,
          activity: epochs[i].activity,
          meanHr: epochs[i].meanHr,
          isSleep: isSleep,
        ),
      );
    }

    return out.reversed.toList();
  }

  static List<_EpochFeature> _buildEpochs(
      List<Map<String, Object?>> rows, {
        required int epochSeconds,
      }) {
    if (rows.isEmpty) return [];

    final epochMs = epochSeconds * 1000;
    final firstTs = rows.first['timestamp_ms'] as int;

    int currentStart = (firstTs ~/ epochMs) * epochMs;
    int currentEnd = currentStart + epochMs;

    double activitySum = 0.0;
    double hrSum = 0.0;
    int hrCount = 0;
    int sampleCount = 0;

    final out = <_EpochFeature>[];

    void flushEpoch() {
      if (sampleCount == 0) return;
      out.add(
        _EpochFeature(
          startMs: currentStart,
          endMs: currentEnd,
          activity: activitySum,
          meanHr: hrCount == 0 ? 0.0 : hrSum / hrCount,
        ),
      );
    }

    for (final r in rows) {
      final t = r['timestamp_ms'] as int;
      final hr = (r['hr_bpm'] as num).toDouble();
      final ax = (r['acc_x'] as num).toDouble();
      final ay = (r['acc_y'] as num).toDouble();
      final az = (r['acc_z'] as num).toDouble();

      while (t >= currentEnd) {
        flushEpoch();
        currentStart = currentEnd;
        currentEnd = currentStart + epochMs;
        activitySum = 0.0;
        hrSum = 0.0;
        hrCount = 0;
        sampleCount = 0;
      }

      final vm = sqrt(ax * ax + ay * ay + az * az);
      final dynamicMotion = (vm - 1.0).abs();

      activitySum += dynamicMotion;
      hrSum += hr;
      hrCount++;
      sampleCount++;
    }

    flushEpoch();
    return out;
  }

  static bool _classifyEpochProxy(List<_EpochFeature> epochs, int i) {
    double activityAt(int index) {
      if (index < 0) return epochs.first.activity;
      if (index >= epochs.length) return epochs.last.activity;
      return epochs[index].activity;
    }

    final current = epochs[i].activity;
    final avg5 = [
      activityAt(i - 2),
      activityAt(i - 1),
      activityAt(i),
      activityAt(i + 1),
      activityAt(i + 2),
    ].reduce((a, b) => a + b) / 5.0;

    final meanHr = epochs[i].meanHr;

    final lowMotion = current < 8.0 && avg5 < 10.0;
    final calmHr = meanHr == 0.0 || meanHr < 75.0;

    return lowMotion && calmHr;
  }
}