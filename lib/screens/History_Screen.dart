import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;

import '../Database/AppDb.dart';
import '../logic/sadeh.dart';

class SleepEpochUI {
  final bool isSleep;
  final int timestamp;

  SleepEpochUI({
    required this.isSleep,
    required this.timestamp,
  });
}

class HistoryScreen extends StatefulWidget {
  final Function(String) onBarTapped;
  final Map<String, dynamic>? initialSession;

  const HistoryScreen({
    super.key,
    required this.onBarTapped,
    this.initialSession,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool isDayView = true;
  DateTime selectedDate = DateTime.now();
  List<Map<String, dynamic>> _allSessions = [];
  List<Map<String, dynamic>> _filteredSessions = [];
  Map<String, dynamic>? _selectedSession;
  List<SleepEpochUI> _currentEpochs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    if (widget.initialSession != null) {
      final session = widget.initialSession!;
      final dynamic rawTs = session['start_time_ms'] ?? session['sleep_onset_ms'];
      final int ts = rawTs is int ? rawTs : (int.tryParse(rawTs.toString()) ?? DateTime.now().millisecondsSinceEpoch);
      selectedDate = DateTime.fromMillisecondsSinceEpoch(ts);
      final dynamic rawId = session['session_id'] ?? session['id'] ?? 0;
      final int targetId = rawId is int ? rawId : int.parse(rawId.toString());
      await _loadData(targetSessionId: targetId);
    } else {
      await _loadData();
    }
  }

  Future<void> _loadData({int? targetSessionId}) async {
    final database = await AppDb.db;
    final sessionData = await database.query('sessions', orderBy: 'start_time_ms DESC');
    final summaryData = await AppDb.getAllSleepSummaries();

    final Map<int, Map<String, dynamic>> summaryMap = {
      for (var s in summaryData) (s['session_id'] as int): s
    };

    final merged = sessionData.map((session) {
      final id = session['session_id'] as int;
      final summary = summaryMap[id];
      return {
        ...session,
        if (summary != null) ...summary,
      };
    }).toList();

    if (mounted) {
      setState(() {
        _allSessions = merged;
        _isLoading = false;

        if (targetSessionId != null && targetSessionId != 0) {
          final match = merged.where((s) => (s['session_id'] ?? s['id']) == targetSessionId);
          _selectedSession = match.isNotEmpty ? match.first : (merged.isNotEmpty ? merged.first : null);
          if (_selectedSession != null) _loadAnalysisForSession(_selectedSession!);
        } else {
          _filterSessionsByDate(selectedDate);
        }
      });
    }
  }

  void _filterSessionsByDate(DateTime date) {
    setState(() {
      selectedDate = date;
      _filteredSessions = _allSessions.where((s) {
        final dynamic ts = s['start_time_ms'] ?? s['sleep_onset_ms'];
        if (ts == null) return false;
        final int timestamp = ts is int ? ts : int.parse(ts.toString());
        final d = DateTime.fromMillisecondsSinceEpoch(timestamp);
        return d.year == date.year && d.month == date.month && d.day == date.day;
      }).toList();

      if (_filteredSessions.isNotEmpty) {
        _loadAnalysisForSession(_filteredSessions.first);
      } else {
        _selectedSession = null;
        _currentEpochs = [];
      }
    });
  }

  Future<void> _loadAnalysisForSession(Map<String, dynamic> session) async {
    final dynamic rawId = session['session_id'] ?? session['id'] ?? 0;
    final int sessionId = rawId is int ? rawId : int.parse(rawId.toString());
    if (sessionId == 0) return;

    final storedEpochs = await AppDb.getScoredEpochsForSession(sessionId);

    if (!mounted) return;

    setState(() {
      _selectedSession = session;
      if (storedEpochs.isNotEmpty) {
        _currentEpochs = storedEpochs.map((e) => SleepEpochUI(
              isSleep: e['label'].toString().trim().toLowerCase() == 'sleep',
              timestamp: (e['epoch_start_ms'] as num? ?? 0).toInt(),
            )).toList();
      } else {
        _currentEpochs = [];
        _repairMissingEpochs(sessionId);
      }
    });
  }

  Future<void> _repairMissingEpochs(int sessionId) async {
    final samples = await AppDb.getSamplesForSession(sessionId);
    if (samples.isNotEmpty) {
      final List<ScoredEpoch> generated = SleepScorer.scoreRows(
        samples,
        algorithm: SleepAlgorithm.sadehScaledConvolved,
        activityScale: 500.0,
      );

      if (mounted) {
        setState(() {
          _currentEpochs = generated.map((e) => SleepEpochUI(
                isSleep: e.isSleep,
                timestamp: e.startMs,
              )).toList();
        });
      }
    }
  }

  String _formatDuration(double minutes) {
    if (minutes <= 0) return "0m";
    int h = minutes ~/ 60;
    int m = (minutes % 60).toInt();
    return h > 0 ? "${h}h ${m}m" : "${m}m";
  }

  Color _getScoreColor(double score) {
    if (score >= 85) return Colors.green;
    if (score >= 70) return Colors.lightGreen;
    if (score >= 60) return Colors.cyanAccent;
    if (score >= 50) return Colors.orange;
    return Colors.red;
  }

  String _getScoreLabel(double score) {
    if (score >= 85) return "Excellent";
    if (score >= 70) return "Good";
    if (score >= 60) return "Fair";
    if (score >= 50) return "Poor";
    return "Very Poor";
  }

  void _showMetricInfo(String title, String description, String tips) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2B5E),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Info:", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(tips, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("continue", style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white54),
            onPressed: () => _showMetricInfo(
              "Understanding Your Sleep Data",
              "Your sleep score is calculated from 4 key metrics:\n\n"
                  "• Duration (47%): Total time asleep\n"
                  "• Efficiency (29%): Sleep time ÷ Time in bed\n"
                  "• Latency (12%): Time to fall asleep\n"
                  "• WASO (12%): Wake after sleep onset\n\n"
                  "Higher scores (85-100) indicate better sleep quality.",
              "• Aim for 7-9 hours of sleep\n"
                  "• Try to fall asleep within 30 minutes\n",
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : RefreshIndicator(
              onRefresh: () => _loadData(),
              color: Colors.cyanAccent,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _buildToggle(),
                    const SizedBox(height: 30),
                    if (isDayView) _buildDayView() else _buildWeekContent(),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildDayView() {
    if (_filteredSessions.isEmpty && _selectedSession == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 100),
        child: Text("No Data for this Date", style: TextStyle(color: Colors.white54)),
      );
    }
    final session = _selectedSession ?? _filteredSessions.first;

    return Column(
      children: [
        _buildScoreCard(session),
        const SizedBox(height: 20),
        _buildMetricGrid(session),
        const SizedBox(height: 30),
        _buildTimelineSection(),
        const SizedBox(height: 30),
        _buildSessionList(),
      ],
    );
  }

  Widget _buildScoreCard(Map<String, dynamic> s) {
    final sleepScore = (s['sleep_score'] as num? ?? 0).toDouble();
    final scoreColor = _getScoreColor(sleepScore);
    final scoreLabel = _getScoreLabel(sleepScore);

    return GestureDetector(
      onTap: () => _showMetricInfo(
        "Sleep Score",
        "Your overall sleep quality score from 0-100.\n\n"
            "It combines 4 metrics: Duration (47%), Efficiency (29%), "
            "Latency (12%), and WASO (12%).\n\n"
            "85-100: Excellent | 70-84: Good | 60-69: Fair | 50-59: Poor | 0-49: Very Poor",
        "• Aim for 85+ for optimal rest\n"
            "• Track trends over time\n",
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scoreColor.withOpacity(0.2),
              scoreColor.withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scoreColor.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Text("Sleep Score", style: TextStyle(color: Colors.white70, fontSize: 14)),
                    SizedBox(width: 4),
                    Icon(Icons.info_outline, color: Colors.white38, size: 14),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "${sleepScore.round()}",
                  style: TextStyle(
                    color: scoreColor,
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  scoreLabel,
                  style: TextStyle(
                    color: scoreColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: CircularProgressIndicator(
                      value: sleepScore / 100,
                      strokeWidth: 8,
                      backgroundColor: Colors.white.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                    ),
                  ),
                  Text(
                    "${sleepScore.round()}",
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("Sleep Analysis", style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
          Text(DateFormat('EEE, MMM dd').format(selectedDate), style: const TextStyle(color: Colors.cyanAccent, fontSize: 16)),
        ]),
        IconButton(
            icon: const Icon(Icons.calendar_month, color: Colors.white),
            onPressed: () async {
              final picked = await showDatePicker(context: context, initialDate: selectedDate, firstDate: DateTime(2024), lastDate: DateTime.now());
              if (picked != null) _filterSessionsByDate(picked);
            }),
      ],
    );
  }

  Widget _buildToggle() {
    return Container(
      height: 40,
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        _toggleBtn("DAY", isDayView, () => setState(() => isDayView = true)),
        _toggleBtn("WEEK", !isDayView, () => setState(() => isDayView = false)),
      ]),
    );
  }

  Widget _toggleBtn(String text, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(color: active ? Colors.cyanAccent : Colors.transparent, borderRadius: BorderRadius.circular(20)),
          alignment: Alignment.center,
          child: Text(text, style: TextStyle(color: active ? const Color(0xFF3F3B76) : Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _buildMetricGrid(Map<String, dynamic> s) {
    final eff = (s['sleep_efficiency_pct'] as num? ?? 0).toDouble();
    final tst = (s['total_sleep_time_min'] as num? ?? 0).toDouble();
    final waso = (s['waso_min'] as num? ?? 0).toDouble();
    final lat = (s['sleep_latency_min'] as num? ?? 0).toDouble();

    String formatClock(dynamic ms) {
      if (ms == null || ms == 0) return "--:--";
      return DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch((ms as num).toInt()));
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 2.5,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        _buildMetricWithInfo("Efficiency", "${eff.toStringAsFixed(1)}%", "Percentage of time in bed that you were actually asleep.\n\n" "Formula: (Total Sleep Time ÷ Time in Bed) × 100", "• 85%+ is considered healthy\n" "• Low efficiency = spending too much time awake in bed\n"),
        _buildMetricWithInfo("Total Sleep", _formatDuration(tst), "Total time you were actually asleep during the session.\n\n" "This excludes time spent awake in bed.", "• Adults need 7-9 hours per night\n" "• Consistency is more important than catching up on weekends\n" "• Short sleep affects next-day performance"),
        _buildMetricWithInfo("Latency", _formatDuration(lat), "How long it took you to fall asleep after going to bed.\n\n" "Time from lights out to first sleep epoch.", "• 15-30 minutes is normal\n" "• >30 minutes may indicate insomnia\n" "• Try relaxation techniques before bed"),
        _buildMetricWithInfo("WASO", _formatDuration(waso), "Wake After Sleep Onset - time spent awake during the night.\n\n" "This includes all awakenings after initially falling asleep.", "• <60 minutes is good\n" "• Brief awakenings are normal\n"),
        _buildMetricWithInfo("Fell Asleep", formatClock(s['sleep_onset_ms']), "The time when you first fell asleep.\n\n" "Based on when sleep was first detected.", "• Consistent bedtimes improve sleep quality\n" "• Try to sleep at the same time every night"),
        _buildMetricWithInfo("Woke Up", formatClock(s['final_wake_ms']), "The time when you finally woke up for the day.\n\n" "The end of your last sleep period.", "• Consistent wake times help regulate circadian rhythm\n" "• Try to wake up at the same time even on weekends"),
      ],
    );
  }

  Widget _buildMetricWithInfo(String label, String value, String description, String tips) {
    return GestureDetector(
      onTap: () => _showMetricInfo(label, description, tips),
      child: Container(
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                const SizedBox(width: 4),
                const Icon(Icons.info_outline, color: Colors.white24, size: 10),
              ],
            ),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineSection() {
    if (_currentEpochs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _showMetricInfo(
            "Sleep Timeline (Hypnogram)",
            "A visual representation of your sleep stages over time\n\n"
                "• Cyan line: Sleep \n"
                "• Orange bars: Wake \n"
                "• The line goes up during wake, down during sleep",
            "• long cyan line = good sleep\n"
                "• Frequent orange bars = restless sleep\n"
                "• Pinch to zoom and swipe to see details",
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Text("Sleep Timeline",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  SizedBox(width: 4),
                  Icon(Icons.info_outline, color: Colors.white38, size: 14),
                ],
              ),
              Row(
                children: [
                  _legendItem("Sleep", Colors.cyanAccent),
                  const SizedBox(width: 12),
                  _legendItem("Wake", Colors.orangeAccent),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 15),
        LayoutBuilder(builder: (context, constraints) {
          final double baseWidth = constraints.maxWidth;
          
          return Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
                color: Colors.black26, borderRadius: BorderRadius.circular(12)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: InteractiveViewer(
                constrained: true, 
                minScale: 1.0,
                maxScale: 15.0,
                child: SizedBox(
                  width: baseWidth,
                  height: 160,
                  child: CustomPaint(
                    size: Size(baseWidth, 160),
                    painter: HypnogramPainter(
                      epochs: _currentEpochs, 
                      stepWidth: baseWidth / _currentEpochs.length,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
        const Padding(
          padding: EdgeInsets.only(top: 8.0),
          child: Center(
            child: Text("← Pinch to zoom • Swipe to scroll →",
                style: TextStyle(
                    color: Colors.white24,
                    fontSize: 10,
                    fontStyle: FontStyle.italic)),
          ),
        )
      ],
    );
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }

  Widget _buildSessionList() {
    if (_filteredSessions.length <= 1) return const SizedBox.shrink();

    return Column(children: [
      const Divider(color: Colors.white10, height: 40),
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text("Other Sessions", style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
      ..._filteredSessions.map((s) {
        final id = s['session_id'] ?? s['id'];
        final isSelected = (_selectedSession?['session_id'] ?? _selectedSession?['id']) == id;
        final sleepScore = (s['sleep_score'] as num? ?? 0).toDouble();
        final scoreColor = _getScoreColor(sleepScore);

        return ListTile(
          onTap: () => _loadAnalysisForSession(s),
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.nights_stay_outlined, color: isSelected ? Colors.cyanAccent : Colors.white24),
          title: Text("Session #$id", style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontSize: 14)),
          subtitle: Text("Score: ${sleepScore.round()} - ${_getScoreLabel(sleepScore)}", style: TextStyle(color: scoreColor, fontSize: 11)),
          trailing: Icon(Icons.arrow_forward_ios, color: isSelected ? Colors.cyanAccent : Colors.white10, size: 14),
        );
      }),
    ]);
  }

  Widget _buildWeekContent() {
    final now = DateTime.now();
    final last7Days = List.generate(7, (i) => DateTime(now.year, now.month, now.day).subtract(Duration(days: i))).reversed.toList();

    Map<String, double> dailySleep = {};
    Map<String, double> dailyScores = {};

    for (var date in last7Days) {
      dailySleep[DateFormat('yyyy-MM-dd').format(date)] = 0.0;
      dailyScores[DateFormat('yyyy-MM-dd').format(date)] = 0.0;
    }

    for (var s in _allSessions) {
      final dynamic rawTs = s['start_time_ms'] ?? s['sleep_onset_ms'] ?? 0;
      final int ts = rawTs is int ? rawTs : int.parse(rawTs.toString());
      if (ts == 0) continue;

      final dateKey = DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts));
      if (dailySleep.containsKey(dateKey)) {
        dailySleep[dateKey] = dailySleep[dateKey]! + (s['total_sleep_time_min'] as num? ?? 0).toDouble();
        final score = (s['sleep_score'] as num? ?? 0).toDouble();
        if (score > 0) dailyScores[dateKey] = dailyScores[dateKey]! + score;
      }
    }

    double totalMinutes = dailySleep.values.fold(0, (sum, item) => sum + item);
    double avgMin = totalMinutes / 7;
    double maxSleep = dailySleep.values.fold(480.0, (max, v) => v > max ? v : max);

    double totalScores = dailyScores.values.fold(0, (sum, item) => sum + item);
    int scoreCount = dailyScores.values.where((v) => v > 0).length;
    double avgScore = scoreCount > 0 ? totalScores / scoreCount : 0;

    return GestureDetector(
      onTap: () => _showMetricInfo(
        "Weekly Overview",
        "Track your sleep patterns over the last 7 days.\n\n"
            "• Bars show total sleep time\n"
            "• Numbers above bars show sleep score\n"
            "• Green bars = good sleep, Orange = short sleep",
        "• Track how weekends affect your sleep",
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _weeklyStat("Avg. Sleep", _formatDuration(avgMin)),
                Container(width: 1, height: 30, color: Colors.white10),
                _weeklyStat("Avg. Score", avgScore > 0 ? "${avgScore.round()}" : "--"),
                Container(width: 1, height: 30, color: Colors.white10),
                _weeklyStat("Days Tracked", "${dailySleep.values.where((v) => v > 0).length}/7"),
              ],
            ),
          ),
          const SizedBox(height: 40),
          SizedBox(
            height: 220,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: last7Days.map((date) {
                final dateKey = DateFormat('yyyy-MM-dd').format(date);
                final double tst = dailySleep[dateKey] ?? 0.0;
                final double barHeight = (tst / maxSleep).clamp(0.02, 1.0) * 140;
                final bool isLow = tst < 360 && tst > 0;
                final double dayScore = dailyScores[dateKey] ?? 0.0;

                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (dayScore > 0)
                        Text(
                          "${dayScore.round()}",
                          style: TextStyle(
                            color: _getScoreColor(dayScore),
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      const SizedBox(height: 2),
                      FittedBox(
                        child: Text(
                          tst == 0 ? "-" : _formatDuration(tst),
                          style: TextStyle(
                            color: tst == 0 ? Colors.white24 : (isLow ? Colors.orangeAccent : Colors.cyanAccent),
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 20,
                        height: barHeight,
                        decoration: BoxDecoration(
                            color: tst == 0 ? Colors.white.withOpacity(0.05) : null,
                            gradient: tst == 0
                                ? null
                                : LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      isLow ? Colors.orangeAccent : Colors.cyanAccent,
                                      isLow ? Colors.orangeAccent.withOpacity(0.2) : Colors.cyanAccent.withOpacity(0.1),
                                    ],
                                  ),
                            borderRadius: BorderRadius.circular(4)),
                      ),
                      const SizedBox(height: 8),
                      Text(DateFormat('E').format(date), style: const TextStyle(color: Colors.white70, fontSize: 10)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _weeklyStat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class HypnogramPainter extends CustomPainter {
  final List<SleepEpochUI> epochs;
  final double stepWidth;

  HypnogramPainter({required this.epochs, required this.stepWidth});

  @override
  void paint(Canvas canvas, Size size) {
    if (epochs.isEmpty) return;

    final double wakeY = size.height * 0.20;
    final double sleepY = size.height * 0.65;
    final double labelY = size.height * 0.85;

    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);
    final Paint linePaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 1.0;

    int labelIntervalMinutes = 60;
    if (epochs.length < 240) labelIntervalMinutes = 30;
    if (epochs.length < 120) labelIntervalMinutes = 15;

    for (int i = 0; i < epochs.length; i++) {
      final DateTime epochTime = DateTime.fromMillisecondsSinceEpoch(epochs[i].timestamp);

      if (epochTime.minute % labelIntervalMinutes == 0 && epochTime.second == 0 || i == 0) {
        double x = i * stepWidth;
        canvas.drawLine(Offset(x, 0), Offset(x, labelY), linePaint);

        String timeLabel = DateFormat('HH:mm').format(epochTime);
        textPainter.text = TextSpan(
          text: timeLabel,
          style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold),
        );
        textPainter.layout();

        double xPos = x - (textPainter.width / 2);
        if (xPos < 0) xPos = 0;
        if (xPos + textPainter.width > size.width) xPos = size.width - textPainter.width;
        
        textPainter.paint(canvas, Offset(xPos, labelY + 4));
      }
    }

    final Path sleepPath = Path();
    final Paint sleepPaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round;

    sleepPath.moveTo(0, epochs[0].isSleep ? sleepY : wakeY);
    for (int i = 0; i < epochs.length; i++) {
      double xStart = i * stepWidth;
      double xEnd = (i + 1) * stepWidth;
      double targetY = epochs[i].isSleep ? sleepY : wakeY;
      
      sleepPath.lineTo(xStart, targetY);
      sleepPath.lineTo(xEnd, targetY);
    }
    canvas.drawPath(sleepPath, sleepPaint);

    final Paint wakeMarkerPaint = Paint()..color = Colors.orangeAccent;
    for (int i = 0; i < epochs.length; i++) {
      if (!epochs[i].isSleep) {
        double rectWidth = stepWidth < 1.0 ? 1.0 : stepWidth;
        canvas.drawRect(
          Rect.fromLTWH(i * stepWidth, wakeY - 4, rectWidth, 8), 
          wakeMarkerPaint
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant HypnogramPainter oldDelegate) => 
      oldDelegate.epochs.length != epochs.length || oldDelegate.stepWidth != stepWidth;
}