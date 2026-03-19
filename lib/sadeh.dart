import 'dart:math';

enum SleepAlgorithm {
  proxy,
  sadehScaled,
  sadehScaledConvolved,
}

class ScoredEpoch {
  final int startMs;
  final int endMs;
  final double activity;
  final double scaledActivity;
  final double convolvedActivity;
  final double meanHr;
  final double sadehScore;
  final bool isSleep;

  const ScoredEpoch({
    required this.startMs,
    required this.endMs,
    required this.activity,
    required this.scaledActivity,
    required this.convolvedActivity,
    required this.meanHr,
    required this.sadehScore,
    required this.isSleep,
  });
}

class SleepMetrics {
  final double timeInBedMinutes;
  final double totalSleepTimeMinutes;
  final double wasoMinutes;
  final double sleepLatencyMinutes;
  final double sleepEfficiency;
  final int? sleepOnsetMs;
  final int? finalWakeMs;

  const SleepMetrics({
    required this.timeInBedMinutes,
    required this.totalSleepTimeMinutes,
    required this.wasoMinutes,
    required this.sleepLatencyMinutes,
    required this.sleepEfficiency,
    required this.sleepOnsetMs,
    required this.finalWakeMs,
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

class _MotionThresholds {
  final double lowAct;
  final double highAct;
  final double lowConv;
  final double highConv;

  const _MotionThresholds({
    required this.lowAct,
    required this.highAct,
    required this.lowConv,
    required this.highConv,
  });
}

class SleepScorer {
  static List<ScoredEpoch> scoreRows(
      List<Map<String, Object?>> rows, {
        int epochSeconds = 30,
        SleepAlgorithm algorithm = SleepAlgorithm.proxy,
        double activityScale = 10.0,
      }) {
    if (rows.isEmpty) return [];

    final sorted = List<Map<String, Object?>>.from(rows)
      ..sort(
            (a, b) =>
            (a['timestamp_ms'] as int).compareTo(b['timestamp_ms'] as int),
      );

    final epochs = _buildEpochs(sorted, epochSeconds: epochSeconds);
    if (epochs.isEmpty) return [];

    final motionThresholds =
    algorithm == SleepAlgorithm.sadehScaledConvolved
        ? _buildMotionThresholds(
      epochs,
      activityScale: activityScale,
    )
        : null;

    final out = <ScoredEpoch>[];

    for (int i = 0; i < epochs.length; i++) {
      final current = epochs[i];
      final conv = _convolvedActivity(epochs, i);
      final scaledActivity = current.activity * activityScale;

      double sadehScore = double.nan;
      bool isSleep;

      switch (algorithm) {
        case SleepAlgorithm.proxy:
          isSleep = _classifyEpochProxy(epochs, i, conv);
          break;

        case SleepAlgorithm.sadehScaled:
          sadehScore = _sadehScoreScaled(
            epochs,
            i,
            activityScale: activityScale,
          );
          isSleep = sadehScore >= 0.0;
          break;

        case SleepAlgorithm.sadehScaledConvolved:
          sadehScore = _sadehScoreScaled(
            epochs,
            i,
            activityScale: activityScale,
          );
          isSleep = _classifyEpochSadehConvolved(
            epochs,
            i,
            sadehScore: sadehScore,
            activityScale: activityScale,
            thresholds: motionThresholds!,
          );
          break;
      }

      out.add(
        ScoredEpoch(
          startMs: current.startMs,
          endMs: current.endMs,
          activity: current.activity,
          scaledActivity: scaledActivity,
          convolvedActivity: conv,
          meanHr: current.meanHr,
          sadehScore: sadehScore,
          isSleep: isSleep,
        ),
      );
    }

    return out.reversed.toList();
  }

  static List<ScoredEpoch> score5sBlocks(
      List<Map<String, Object?>> blocks, {
        int epochSeconds = 30,
        SleepAlgorithm algorithm = SleepAlgorithm.proxy,
        double activityScale = 10.0,
      }) {
    if (blocks.isEmpty) return [];

    final sorted = List<Map<String, Object?>>.from(blocks)
      ..sort(
            (a, b) =>
            (a['block_start_ms'] as int).compareTo(b['block_start_ms'] as int),
      );

    final epochs = _buildEpochsFrom5sBlocks(
      sorted,
      epochSeconds: epochSeconds,
    );
    if (epochs.isEmpty) return [];

    final motionThresholds =
    algorithm == SleepAlgorithm.sadehScaledConvolved
        ? _buildMotionThresholds(
      epochs,
      activityScale: activityScale,
    )
        : null;

    final out = <ScoredEpoch>[];

    for (int i = 0; i < epochs.length; i++) {
      final current = epochs[i];
      final conv = _convolvedActivity(epochs, i);
      final scaledActivity = current.activity * activityScale;

      double sadehScore = double.nan;
      bool isSleep;

      switch (algorithm) {
        case SleepAlgorithm.proxy:
          isSleep = _classifyEpochProxy(epochs, i, conv);
          break;

        case SleepAlgorithm.sadehScaled:
          sadehScore = _sadehScoreScaled(
            epochs,
            i,
            activityScale: activityScale,
          );
          isSleep = sadehScore >= 0.0;
          break;

        case SleepAlgorithm.sadehScaledConvolved:
          sadehScore = _sadehScoreScaled(
            epochs,
            i,
            activityScale: activityScale,
          );
          isSleep = _classifyEpochSadehConvolved(
            epochs,
            i,
            sadehScore: sadehScore,
            activityScale: activityScale,
            thresholds: motionThresholds!,
          );
          break;
      }

      out.add(
        ScoredEpoch(
          startMs: current.startMs,
          endMs: current.endMs,
          activity: current.activity,
          scaledActivity: scaledActivity,
          convolvedActivity: conv,
          meanHr: current.meanHr,
          sadehScore: sadehScore,
          isSleep: isSleep,
        ),
      );
    }

    return out.reversed.toList();
  }

  static SleepMetrics calculateMetrics(List<ScoredEpoch> epochs) {
    if (epochs.isEmpty) {
      return const SleepMetrics(
        timeInBedMinutes: 0,
        totalSleepTimeMinutes: 0,
        wasoMinutes: 0,
        sleepLatencyMinutes: 0,
        sleepEfficiency: 0,
        sleepOnsetMs: null,
        finalWakeMs: null,
      );
    }

    final sorted = List<ScoredEpoch>.from(epochs)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final firstStartMs = sorted.first.startMs;
    final lastEndMs = sorted.last.endMs;
    final epochDurationMs = sorted.first.endMs - sorted.first.startMs;
    final epochDurationMinutes = epochDurationMs / 60000.0;

    final timeInBedMinutes = (lastEndMs - firstStartMs) / 60000.0;

    int? sleepOnsetIndex;
    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i].isSleep) {
        sleepOnsetIndex = i;
        break;
      }
    }

    int? lastSleepIndex;
    for (int i = sorted.length - 1; i >= 0; i--) {
      if (sorted[i].isSleep) {
        lastSleepIndex = i;
        break;
      }
    }

    if (sleepOnsetIndex == null || lastSleepIndex == null) {
      return SleepMetrics(
        timeInBedMinutes: timeInBedMinutes,
        totalSleepTimeMinutes: 0,
        wasoMinutes: 0,
        sleepLatencyMinutes: timeInBedMinutes,
        sleepEfficiency: 0,
        sleepOnsetMs: null,
        finalWakeMs: null,
      );
    }

    final sleepEpochs = sorted.where((e) => e.isSleep).length;
    final totalSleepTimeMinutes = sleepEpochs * epochDurationMinutes;

    final sleepOnsetMs = sorted[sleepOnsetIndex].startMs;
    final sleepLatencyMinutes = (sleepOnsetMs - firstStartMs) / 60000.0;

    double wasoMinutes = 0.0;
    for (int i = sleepOnsetIndex + 1; i <= lastSleepIndex; i++) {
      if (!sorted[i].isSleep) {
        wasoMinutes += epochDurationMinutes;
      }
    }

    final sleepEfficiency = timeInBedMinutes == 0
        ? 0.0
        : (totalSleepTimeMinutes / timeInBedMinutes) * 100.0;

    int? finalWakeMs;
    for (int i = lastSleepIndex + 1; i < sorted.length; i++) {
      if (!sorted[i].isSleep) {
        finalWakeMs = sorted[i].startMs;
        break;
      }
    }

    return SleepMetrics(
      timeInBedMinutes: timeInBedMinutes,
      totalSleepTimeMinutes: totalSleepTimeMinutes,
      wasoMinutes: wasoMinutes,
      sleepLatencyMinutes: sleepLatencyMinutes,
      sleepEfficiency: sleepEfficiency,
      sleepOnsetMs: sleepOnsetMs,
      finalWakeMs: finalWakeMs,
    );
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

    double? lastAx;
    double? lastAy;
    double? lastAz;

    final out = <_EpochFeature>[];

    void flushEpoch() {
      if (sampleCount == 0) return;
      out.add(
        _EpochFeature(
          startMs: currentStart,
          endMs: currentEnd,
          activity: activitySum / sampleCount,
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

      double dynamicMotion = 0.0;
      if (lastAx != null && lastAy != null && lastAz != null) {
        final dx = ax - lastAx;
        final dy = ay - lastAy;
        final dz = az - lastAz;
        dynamicMotion = sqrt(dx * dx + dy * dy + dz * dz);
      }

      activitySum += dynamicMotion;

      lastAx = ax;
      lastAy = ay;
      lastAz = az;

      if (hr >= 0) {
        hrSum += hr;
        hrCount++;
      }

      sampleCount++;
    }

    flushEpoch();
    return out;
  }

  static List<_EpochFeature> _buildEpochsFrom5sBlocks(
      List<Map<String, Object?>> blocks, {
        required int epochSeconds,
      }) {
    if (blocks.isEmpty) return [];

    final epochMs = epochSeconds * 1000;
    final firstTs = blocks.first['block_start_ms'] as int;

    int currentStart = (firstTs ~/ epochMs) * epochMs;
    int currentEnd = currentStart + epochMs;

    double activityWeightedSum = 0.0;
    int activitySampleCount = 0;

    double hrWeightedSum = 0.0;
    int hrSampleCount = 0;

    int blockCount = 0;

    final out = <_EpochFeature>[];

    void flushEpoch() {
      if (blockCount == 0) return;

      out.add(
        _EpochFeature(
          startMs: currentStart,
          endMs: currentEnd,
          activity: activitySampleCount == 0
              ? 0.0
              : activityWeightedSum / activitySampleCount,
          meanHr: hrSampleCount == 0 ? 0.0 : hrWeightedSum / hrSampleCount,
        ),
      );
    }

    for (final b in blocks) {
      final blockStart = b['block_start_ms'] as int;
      final sampleCount = (b['sample_count'] as num).toInt();
      final meanHr = (b['mean_hr'] as num).toDouble();
      final blockActivityMean = (b['activity_mean'] as num).toDouble();

      while (blockStart >= currentEnd) {
        flushEpoch();
        currentStart = currentEnd;
        currentEnd = currentStart + epochMs;

        activityWeightedSum = 0.0;
        activitySampleCount = 0;
        hrWeightedSum = 0.0;
        hrSampleCount = 0;
        blockCount = 0;
      }

      if (sampleCount > 0) {
        activityWeightedSum += blockActivityMean * sampleCount;
        activitySampleCount += sampleCount;
      }

      if (sampleCount > 0 && meanHr >= 0) {
        hrWeightedSum += meanHr * sampleCount;
        hrSampleCount += sampleCount;
      }

      blockCount++;
    }

    flushEpoch();
    return out;
  }

  static double _convolvedActivity(List<_EpochFeature> epochs, int i) {
    const kernel = [0.04, 0.2, 0.52, 0.2, 0.04];

    double activityAt(int index) {
      if (index < 0) return epochs.first.activity;
      if (index >= epochs.length) return epochs.last.activity;
      return epochs[index].activity;
    }

    double sum = 0.0;
    for (int k = -2; k <= 2; k++) {
      final weight = kernel[k + 2];
      sum += weight * activityAt(i + k);
    }

    return sum;
  }

  static bool _classifyEpochProxy(
      List<_EpochFeature> epochs,
      int i,
      double conv,
      ) {
    final current = epochs[i].activity;
    final meanHr = epochs[i].meanHr;

    final lowMotion = current < 8.0 && conv < 10.0;

    final hasValidHr = meanHr > 0.0;
    final calmHr = hasValidHr && meanHr < 75.0;

    if (hasValidHr) {
      return lowMotion && calmHr;
    }

    return lowMotion;
  }

  static bool _classifyEpochSadehConvolved(
      List<_EpochFeature> epochs,
      int i, {
        required double sadehScore,
        required double activityScale,
        required _MotionThresholds thresholds,
      }) {
    final scaledActivity = _scaledActivityAt(
      epochs,
      i,
      activityScale: activityScale,
    );

    final scaledConv = _convolvedActivity(epochs, i) * activityScale;

    if (sadehScore < 0.0) {
      return false;
    }

    if (scaledActivity <= thresholds.lowAct &&
        scaledConv <= thresholds.lowConv) {
      return true;
    }

    if (scaledActivity >= thresholds.highAct ||
        scaledConv >= thresholds.highConv) {
      return false;
    }

    final midAct = (thresholds.lowAct + thresholds.highAct) / 2.0;
    final midConv = (thresholds.lowConv + thresholds.highConv) / 2.0;

    return sadehScore >= 1.0 &&
        scaledActivity <= midAct &&
        scaledConv <= midConv;
  }

  static _MotionThresholds _buildMotionThresholds(
      List<_EpochFeature> epochs, {
        required double activityScale,
      }) {
    final acts = <double>[];
    final convs = <double>[];

    for (int i = 0; i < epochs.length; i++) {
      acts.add(
        _scaledActivityAt(
          epochs,
          i,
          activityScale: activityScale,
        ),
      );
      convs.add(_convolvedActivity(epochs, i) * activityScale);
    }

    final lowAct = _percentile(acts, 0.35);
    final highAct = _percentile(acts, 0.65);
    final lowConv = _percentile(convs, 0.35);
    final highConv = _percentile(convs, 0.65);

    return _MotionThresholds(
      lowAct: lowAct,
      highAct: highAct,
      lowConv: lowConv,
      highConv: highConv,
    );
  }

  static double _percentile(List<double> values, double p) {
    if (values.isEmpty) return 0.0;

    final sorted = List<double>.from(values)..sort();
    final rawIndex = ((sorted.length - 1) * p).round();

    int index = rawIndex;
    if (index < 0) index = 0;
    if (index >= sorted.length) index = sorted.length - 1;

    return sorted[index];
  }

  static double _scaledActivityAt(
      List<_EpochFeature> epochs,
      int index, {
        required double activityScale,
      }) {
    if (index < 0) index = 0;
    if (index >= epochs.length) index = epochs.length - 1;
    return epochs[index].activity * activityScale;
  }

  static double _meanW5Scaled(
      List<_EpochFeature> epochs,
      int i, {
        required double activityScale,
      }) {
    double sum = 0.0;
    int count = 0;

    for (int k = -5; k <= 5; k++) {
      sum += _scaledActivityAt(
        epochs,
        i + k,
        activityScale: activityScale,
      );
      count++;
    }

    return count == 0 ? 0.0 : sum / count;
  }

  static double _sdLast6Scaled(
      List<_EpochFeature> epochs,
      int i, {
        required double activityScale,
      }) {
    final values = <double>[];

    for (int k = -5; k <= 0; k++) {
      values.add(
        _scaledActivityAt(
          epochs,
          i + k,
          activityScale: activityScale,
        ),
      );
    }

    final mean = values.reduce((a, b) => a + b) / values.length;

    double sumSq = 0.0;
    for (final v in values) {
      final d = v - mean;
      sumSq += d * d;
    }

    return sqrt(sumSq / values.length);
  }

  static double _natScaled(
      List<_EpochFeature> epochs,
      int i, {
        required double activityScale,
      }) {
    int count = 0;

    for (int k = -5; k <= 5; k++) {
      final a = _scaledActivityAt(
        epochs,
        i + k,
        activityScale: activityScale,
      );

      if (a >= 50.0 && a < 100.0) {
        count++;
      }
    }

    return count.toDouble();
  }

  static double _sadehScoreScaled(
      List<_EpochFeature> epochs,
      int i, {
        required double activityScale,
      }) {
    final act = _scaledActivityAt(
      epochs,
      i,
      activityScale: activityScale,
    );

    final meanW5 = _meanW5Scaled(
      epochs,
      i,
      activityScale: activityScale,
    );

    final nat = _natScaled(
      epochs,
      i,
      activityScale: activityScale,
    );

    final sdLast6 = _sdLast6Scaled(
      epochs,
      i,
      activityScale: activityScale,
    );

    final logAct = log(act + 1.0);

    return 7.601 -
        (0.065 * meanW5) -
        (1.08 * nat) -
        (0.056 * sdLast6) -
        (0.703 * logAct);
  }
}