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
  bool isSleep; 

  ScoredEpoch({
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
  // MAIN ENTRY POINT
  static List<ScoredEpoch> scoreRows(
    List<Map<String, Object?>> rows, {
    int epochSeconds = 30,
    SleepAlgorithm algorithm = SleepAlgorithm.sadehScaledConvolved,
    double activityScale = 0.1, 
  }) {
    if (rows.isEmpty) return [];

    final sorted = List<Map<String, Object?>>.from(rows)
      ..sort((a, b) => (a['timestamp_ms'] as int).compareTo(b['timestamp_ms'] as int));

    final epochs = _buildEpochs(sorted, epochSeconds: epochSeconds);
    return _processScoring(epochs, algorithm, activityScale);
  }

  static List<ScoredEpoch> _processScoring(
    List<_EpochFeature> epochs,
    SleepAlgorithm algorithm,
    double activityScale,
  ) {
    if (epochs.isEmpty) return [];

    final validHrs = epochs.where((e) => e.meanHr > 10).map((e) => e.meanHr).toList();
    final sessionAvgHr = validHrs.isEmpty ? 0.0 : validHrs.reduce((a, b) => a + b) / validHrs.length;

    final motionThresholds = algorithm == SleepAlgorithm.sadehScaledConvolved
        ? _buildMotionThresholds(epochs, activityScale: activityScale)
        : null;

    final out = <ScoredEpoch>[];

    for (int i = 0; i < epochs.length; i++) {
      final current = epochs[i];
      final conv = _convolvedActivity(epochs, i);
      final scaledActivity = current.activity * activityScale;

      // Calculate Sadeh Base Score
      double sadehScore = _calculateSadehBase(epochs, i, activityScale);
      
      // HR Refinement
      if (sessionAvgHr > 0 && current.meanHr > sessionAvgHr * 1.25) {
        sadehScore -= 1.0; 
      }

      // Classification
      bool isSleep;
      if (algorithm == SleepAlgorithm.sadehScaled) {
        isSleep = sadehScore >= 0.0;
      } else {
        isSleep = _classifyEpochSadehConvolved(
          epochs, i,
          sadehScore: sadehScore,
          activityScale: activityScale,
          thresholds: motionThresholds!,
        );
      }

      out.add(ScoredEpoch(
        startMs: current.startMs,
        endMs: current.endMs,
        activity: current.activity,
        scaledActivity: scaledActivity,
        convolvedActivity: conv,
        meanHr: current.meanHr,
        sadehScore: sadehScore,
        isSleep: isSleep,
      ));
    }

    return _applySmoothing(out);
  }

  // SADEH
  static double _calculateSadehBase(List<_EpochFeature> epochs, int i, double scale) {
    double actAt(int idx) => epochs[idx.clamp(0, epochs.length - 1)].activity * scale;
    
    double sumW11 = 0;
    for (int k = -5; k <= 5; k++) sumW11 += actAt(i + k);
    final meanW11 = sumW11 / 11;
  
    int nat = 0;
    for (int k = -5; k <= 5; k++) {
      final a = actAt(i + k);
      if (a >= 20.0 && a < 80.0) nat++;
    }

    final last6 = List.generate(6, (k) => actAt(i - 5 + k));
    final m6 = last6.reduce((a, b) => a + b) / 6;
    final sd6 = sqrt(last6.map((v) => pow(v - m6, 2)).reduce((a, b) => a + b) / 6);

    double currentAct = actAt(i);
    double logPenalty = (currentAct > 2.0) ? (0.75 * log(currentAct + 1.0)) : 0.0;

    // Increased constant to 15.0 to handle M5StickC sensitivity
    return 15.0 - (0.065 * meanW11) - (1.08 * nat) - (0.056 * sd6) - logPenalty;
  }

  static List<ScoredEpoch> _applySmoothing(List<ScoredEpoch> epochs) {
    if (epochs.length < 5) return epochs;

    for (int i = 1; i < epochs.length - 1; i++) {
      if (epochs[i - 1].isSleep && epochs[i + 1].isSleep && !epochs[i].isSleep) {
        if (epochs[i].scaledActivity < 20.0) {
          epochs[i].isSleep = true;
        }
      }
      if (!epochs[i - 1].isSleep && !epochs[i + 1].isSleep && epochs[i].isSleep) {
        epochs[i].isSleep = false;
      }
    }
    return epochs;
  }

  // CALCULATE SUMMARY
  static SleepMetrics calculateMetrics(List<ScoredEpoch> epochs) {
    if (epochs.isEmpty) return const SleepMetrics(timeInBedMinutes: 0, totalSleepTimeMinutes: 0, wasoMinutes: 0, sleepLatencyMinutes: 0, sleepEfficiency: 0, sleepOnsetMs: null, finalWakeMs: null);
    
    final sorted = List<ScoredEpoch>.from(epochs)..sort((a, b) => a.startMs.compareTo(b.startMs));
    final durationMin = (sorted.first.endMs - sorted.first.startMs) / 60000.0;
    final tib = (sorted.last.endMs - sorted.first.startMs) / 60000.0;

    // Lowered streak to 4 (2 mins) so short table tests don't stay at 0%
    int onsetIdx = -1;
    int streak = 0;
    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i].isSleep) {
        streak++;
        if (streak >= 4) { onsetIdx = i - 3; break; }
      } else { streak = 0; }
    }

    if (onsetIdx == -1) return SleepMetrics(timeInBedMinutes: tib, totalSleepTimeMinutes: 0, wasoMinutes: 0, sleepLatencyMinutes: tib, sleepEfficiency: 0, sleepOnsetMs: null, finalWakeMs: null);

    int lastSleepIdx = sorted.lastIndexWhere((e) => e.isSleep);
    double tst = 0, waso = 0;

    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i].isSleep) {
        tst += durationMin;
      } else if (i > onsetIdx && i < lastSleepIdx) {
        waso += durationMin;
      }
    }

    return SleepMetrics(
      timeInBedMinutes: tib,
      totalSleepTimeMinutes: tst,
      wasoMinutes: waso,
      sleepLatencyMinutes: (sorted[onsetIdx].startMs - sorted.first.startMs) / 60000.0,
      sleepEfficiency: (tst / tib) * 100,
      sleepOnsetMs: sorted[onsetIdx].startMs,
      finalWakeMs: sorted[lastSleepIdx].endMs,
    );
  }

  static List<_EpochFeature> _buildEpochs(List<Map<String, Object?>> rows, {required int epochSeconds}) {
    final epochMs = epochSeconds * 1000;
    int currentStart = ((rows.first['timestamp_ms'] as int) ~/ epochMs) * epochMs;
    int currentEnd = currentStart + epochMs;

    double actSum = 0, hrSum = 0;
    int hrCount = 0, count = 0;
    double? lx, ly, lz;
    final out = <_EpochFeature>[];

    void flush() {
      if (count > 0) {
        out.add(_EpochFeature(
          startMs: currentStart, endMs: currentEnd,
          activity: actSum / count, meanHr: hrCount > 0 ? hrSum / hrCount : 0,
        ));
      }
    }

    for (final r in rows) {
      final t = r['timestamp_ms'] as int;
      while (t >= currentEnd) {
        flush();
        currentStart = currentEnd; currentEnd += epochMs;
        actSum = 0; hrSum = 0; hrCount = 0; count = 0;
      }
      final ax = (r['acc_x'] as num).toDouble();
      final ay = (r['acc_y'] as num).toDouble();
      final az = (r['acc_z'] as num).toDouble();
      
      if (lx != null) {
        double diff = sqrt(pow(ax-lx, 2) + pow(ay-ly!, 2) + pow(az-lz!, 2));
        // Noise floor filtering for stationary M5Stack devices
        actSum += (diff < 0.02) ? 0 : diff; 
      }
      lx = ax; ly = ay; lz = az;
      
      final hr = (r['hr_bpm'] as num).toDouble();
      if (hr > 10) { hrSum += hr; hrCount++; }
      count++;
    }
    flush();
    return out;
  }

  static double _convolvedActivity(List<_EpochFeature> epochs, int i) {
    const k = [0.04, 0.2, 0.52, 0.2, 0.04];
    double s = 0;
    for (int j = -2; j <= 2; j++) s += k[j+2] * epochs[(i+j).clamp(0, epochs.length-1)].activity;
    return s;
  }

  static bool _classifyEpochSadehConvolved(List<_EpochFeature> epochs, int i, {required double sadehScore, required double activityScale, required _MotionThresholds thresholds}) {
    final a = epochs[i].activity * activityScale;
    final c = _convolvedActivity(epochs, i) * activityScale;
    
    // High threshold for Sadeh score to allow sleep during small noise blips
    if (sadehScore < -1.0) return false;
    if (a <= thresholds.lowAct && c <= thresholds.lowConv) return true;
    if (a >= thresholds.highAct || c >= thresholds.highConv) return false;
    return sadehScore >= 0.0;
  }

  static _MotionThresholds _buildMotionThresholds(List<_EpochFeature> epochs, {required double activityScale}) {
    final a = epochs.map((e) => e.activity * activityScale).toList();
    final c = List.generate(epochs.length, (i) => _convolvedActivity(epochs, i) * activityScale);
    return _MotionThresholds(
      lowAct: _perc(a, 0.3), highAct: _perc(a, 0.7),
      lowConv: _perc(c, 0.3), highConv: _perc(c, 0.7),
    );
  }

  static double _perc(List<double> v, double p) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    return s[((s.length - 1) * p).round().clamp(0, s.length - 1)];
  }
}