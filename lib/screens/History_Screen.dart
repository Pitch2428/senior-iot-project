import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/rendering.dart';

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
  final GlobalKey _screenshotKey = GlobalKey();
  
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

  Future<void> _takeScreenshot() async {
    try {
      final boundary = _screenshotKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final imageBytes = byteData!.buffer.asUint8List();
      
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final imagePath = '${directory.path}/history_screenshot_$timestamp.png';
      final file = await File(imagePath).writeAsBytes(imageBytes);
      
      await Share.shareXFiles([XFile(file.path)], subject: 'Sleep History Screenshot');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Screenshot saved!")),
        );
      }
    } catch (e) {
      debugPrint('Screenshot error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Screenshot failed: $e")),
        );
      }
    }
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
        activityScale: 1.0,
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
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                  Text(tips, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Got it", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
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
            icon: const Icon(Icons.camera_alt, color: Colors.white),
            onPressed: _takeScreenshot,
            tooltip: "Take Screenshot",
          ),
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white60),
            onPressed: () => _showMetricInfo(
              "Understanding Your Sleep Data",
              "Your sleep score is calculated from 4 key metrics:\n\n"
                  "• Duration (47%): Total time asleep\n"
                  "• Efficiency (29%): Sleep time ÷ Time in bed\n"
                  "• Latency (12%): Time to fall asleep\n"
                  "• WASO (12%): Wake after sleep onset\n\n"
                  "Higher scores (85-100) indicate better sleep quality.",
              "• Aim for 7-9 hours of sleep\n"
            ),
          ),
        ],
      ),
      body: RepaintBoundary(
        key: _screenshotKey,
        child: _isLoading
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
      ),
    );
  }

  Widget _buildDayView() {
    if (_filteredSessions.isEmpty && _selectedSession == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 100),
        child: Text("No Data for this Date", style: TextStyle(color: Colors.white60, fontSize: 16)),
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
                    fontWeight: FontWeight.w600,
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
          const Text("Sleep Analysis", style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(DateFormat('EEEE, MMM d').format(selectedDate), style: const TextStyle(color: Colors.cyanAccent, fontSize: 16, fontWeight: FontWeight.w500)),
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
          child: Text(text, style: TextStyle(color: active ? const Color(0xFF3F3B76) : Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
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
        _buildMetricWithInfo("Efficiency", "${eff.toStringAsFixed(1)}%", "Percentage of time in bed that you were actually asleep.\n\n" "Formula: (Total Sleep Time ÷ Time in Bed) × 100", "• 85%+ is considered healthy\n" "• Low efficiency = spending too much time awake in bed\n" "• Try to limit time in bed if not sleeping"),
        _buildMetricWithInfo("Total Sleep", _formatDuration(tst), "Total time you were actually asleep during the session.\n\n" "This excludes time spent awake in bed.", "• Adults need 7-9 hours per night\n" "• Consistency is more important than catching up on weekends\n" "• Short sleep affects next-day performance"),
        _buildMetricWithInfo("Latency", _formatDuration(lat), "How long it took you to fall asleep after going to bed.\n\n" "Time from lights out to first sleep epoch.", "• 15-30 minutes is normal\n" "• >30 minutes may indicate insomnia\n" "• Try relaxation techniques before bed"),
        _buildMetricWithInfo("WASO", _formatDuration(waso), "Wake After Sleep Onset - time spent awake during the night.\n\n" "This includes all awakenings after initially falling asleep.", "• <60 minutes is good\n" "• Brief awakenings are normal\n" "• Frequent waking may indicate sleep apnea"),
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
                Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.w500)),
                const SizedBox(width: 4),
                const Icon(Icons.info_outline, color: Colors.white38, size: 10),
              ],
            ),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineSection() {
    if (_currentEpochs.isEmpty) return const SizedBox.shrink();

    // Calculate total duration for better time labels
    final firstTimestamp = _currentEpochs.first.timestamp;
    final lastTimestamp = _currentEpochs.last.timestamp;
    final totalMinutes = (lastTimestamp - firstTimestamp) / 60000;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _showMetricInfo(
            "Sleep Timeline (Hypnogram)",
            "A visual representation of your sleep/wake states over time\n\n"
                "• Blue line going DOWN = Sleep\n"
                "• Blue line going UP = Wake\n"
                "• Orange bars = Wake episodes\n\n"
                "This chart shows your entire sleep session at a glance.",
            "• Long blue sections = good sleep\n"
                "• Frequent orange bars = restless sleep\n"
                "• Multiple wake-ups near the end = natural light sleep phase",
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Text("Sleep Timeline",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  SizedBox(width: 6),
                  Icon(Icons.info_outline, color: Colors.white38, size: 16),
                ],
              ),
              Row(
                children: [
                  _legendItem("Asleep", Colors.cyanAccent),
                  const SizedBox(width: 16),
                  _legendItem("Awake", Colors.orangeAccent),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              // Time labels bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: _buildTimeLabels(),
                ),
              ),
              // Timeline chart
              SizedBox(
                height: 200,
                width: double.infinity,
                child: CustomPaint(
                  size: Size(MediaQuery.of(context).size.width - 40, 200),
                  painter: ImprovedHypnogramPainter(
                    epochs: _currentEpochs,
                  ),
                ),
              ),
              // Simple legend
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(width: 20, height: 3, color: Colors.cyanAccent),
                    const SizedBox(width: 6),
                    const Text("Sleep", style: TextStyle(color: Colors.white60, fontSize: 11)),
                    const SizedBox(width: 20),
                    Container(width: 20, height: 3, color: Colors.orangeAccent),
                    const SizedBox(width: 6),
                    const Text("Wake", style: TextStyle(color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildTimeLabels() {
    if (_currentEpochs.isEmpty) return [];
    
    final firstTime = DateTime.fromMillisecondsSinceEpoch(_currentEpochs.first.timestamp);
    final lastTime = DateTime.fromMillisecondsSinceEpoch(_currentEpochs.last.timestamp);
    final totalDuration = lastTime.difference(firstTime).inMinutes;
    
    // Show 4-6 time labels
    final numLabels = 5;
    final intervalMinutes = (totalDuration / (numLabels - 1)).toInt();
    
    List<Widget> labels = [];
    for (int i = 0; i < numLabels; i++) {
      final labelTime = firstTime.add(Duration(minutes: intervalMinutes * i));
      final timeString = DateFormat('h:mm a').format(labelTime);
      labels.add(
        Text(
          timeString,
          style: const TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.w500),
        ),
      );
    }
    
    return labels;
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(width: 14, height: 14, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildSessionList() {
    if (_filteredSessions.length <= 1) return const SizedBox.shrink();

    return Column(children: [
      const Divider(color: Colors.white10, height: 40),
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text("Other Sessions", style: TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500)),
      ),
      ..._filteredSessions.map((s) {
        final id = s['session_id'] ?? s['id'];
        final isSelected = (_selectedSession?['session_id'] ?? _selectedSession?['id']) == id;
        final sleepScore = (s['sleep_score'] as num? ?? 0).toDouble();
        final scoreColor = _getScoreColor(sleepScore);

        return ListTile(
          onTap: () => _loadAnalysisForSession(s),
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.nights_stay_outlined, color: isSelected ? Colors.cyanAccent : Colors.white38, size: 20),
          title: Text("Session #$id", style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 14, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400)),
          subtitle: Text("Score: ${sleepScore.round()} — ${_getScoreLabel(sleepScore)}", style: TextStyle(color: scoreColor, fontSize: 12, fontWeight: FontWeight.w500)),
          trailing: Icon(Icons.arrow_forward_ios, color: isSelected ? Colors.cyanAccent : Colors.white24, size: 14),
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
        "• Track how weekends affect your sleep\n"
            "• Aim for consistency across all days",
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
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      const SizedBox(height: 2),
                      FittedBox(
                        child: Text(
                          tst == 0 ? "—" : _formatDuration(tst),
                          style: TextStyle(
                            color: tst == 0 ? Colors.white38 : (isLow ? Colors.orangeAccent : Colors.cyanAccent),
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 24,
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
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      const SizedBox(height: 8),
                      Text(DateFormat('E').format(date), style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
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
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// Improved Hypnogram Painter - cleaner, clearer, no zoom/swipe needed
class ImprovedHypnogramPainter extends CustomPainter {
  final List<SleepEpochUI> epochs;

  ImprovedHypnogramPainter({required this.epochs});

  @override
  void paint(Canvas canvas, Size size) {
    if (epochs.isEmpty || size.width <= 0) return;

    final double topY = size.height * 0.15;      // Wake area top
    final double sleepY = size.height * 0.75;    // Sleep area bottom
    final double awakeY = size.height * 0.25;    // Wake line position
    
    final double epochWidth = size.width / epochs.length;
    
    // Draw background alternating pattern
    final Paint bgPaint = Paint()..color = Colors.white.withOpacity(0.03);
    for (int i = 0; i < epochs.length; i++) {
      if (i % 2 == 0) {
        canvas.drawRect(
          Rect.fromLTWH(i * epochWidth, 0, epochWidth, size.height),
          bgPaint,
        );
      }
    }
    
    // Draw horizontal reference lines
    final Paint linePaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..strokeWidth = 0.5;
    
    canvas.drawLine(Offset(0, sleepY), Offset(size.width, sleepY), linePaint);
    canvas.drawLine(Offset(0, awakeY), Offset(size.width, awakeY), linePaint);
    
    // Draw the sleep/wake line
    final Path sleepPath = Path();
    final Paint linePaintMain = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    
    // Draw filled area under the curve
    final Path fillPath = Path();
    final Paint fillPaint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.15)
      ..style = PaintingStyle.fill;
    
    for (int i = 0; i < epochs.length; i++) {
      double x = i * epochWidth;
      double y = epochs[i].isSleep ? sleepY : awakeY;
      
      if (i == 0) {
        sleepPath.moveTo(x, y);
        fillPath.moveTo(x, sleepY);
        fillPath.lineTo(x, y);
      } else {
        sleepPath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    
    // Complete fill path
    fillPath.lineTo(size.width, sleepY);
    fillPath.lineTo(0, sleepY);
    fillPath.close();
    
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(sleepPath, linePaintMain);
    
    // Draw wake markers (orange bars at the top)
    final Paint wakePaint = Paint()
      ..color = Colors.orangeAccent
      ..style = PaintingStyle.fill;
    
    for (int i = 0; i < epochs.length; i++) {
      if (!epochs[i].isSleep) {
        double x = i * epochWidth;
        double barWidth = epochWidth * 0.7;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + (epochWidth - barWidth) / 2, topY, barWidth, size.height * 0.08),
            const Radius.circular(3),
          ),
          wakePaint,
        );
      }
    }
    
    // Add small labels
    final TextPainter textPainter = TextPainter(textDirection: ui.TextDirection.ltr);
    
    textPainter.text = TextSpan(
      text: "💤 SLEEP",
      style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(8, sleepY - 12));
    
    textPainter.text = TextSpan(
      text: "🌙 AWAKE",
      style: const TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(8, awakeY - 12));
  }

  @override
  bool shouldRepaint(covariant ImprovedHypnogramPainter oldDelegate) {
    return oldDelegate.epochs.length != epochs.length;
  }
}