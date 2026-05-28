import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../Database/AppDb.dart';
import '../screens/history_screen.dart';
import '../logic/sadeh.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

// ==================== CONSTANTS ====================

const _scoreColorExcellent = Color(0xFF4CAF50);
const _scoreColorGood = Color(0xFF8BC34A);
const _scoreColorFair = Color(0xFFFFC107);
const _scoreColorPoor = Color(0xFFFF9800);
const _scoreColorVeryPoor = Color(0xFFF44336);

const _baseEpoch = 100000;
const _epochStep = 30000;

// ==================== MAIN WIDGET ====================

class JournalScreen extends StatefulWidget {
  final String? highlightDate;
  final Function(Map<String, dynamic>)? onSessionTap;

  const JournalScreen({
    super.key,
    this.highlightDate,
    this.onSessionTap,
  });

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  bool _isLoading = true;
  bool _isProcessing = false;
  List<Map<String, dynamic>> _nights = [];
  
  // Set to true for presentation screenshots, false for normal app use
  bool _demoMode = false;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  // ==================== DATA LOADING ====================

  Future<void> _loadSessions() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // DEMO MODE: For clean presentation screenshots
      if (_demoMode) {
        final demoSessions = _generateRealisticDemoSessions();
        setState(() {
          _nights = demoSessions;
          _isLoading = false;
        });
        return;
      }
      
      // REAL DATA MODE
      final db = await AppDb.db;
      final sessions = await db.query('sessions', orderBy: 'start_time_ms DESC');

      final List<Map<String, dynamic>> combined = [];

      for (final session in sessions) {
        final sessionId = _parseSessionId(session['session_id']);
        final summary = await _getSummaryForSession(db, sessionId);

        combined.add(_buildSessionData(session, sessionId, summary));
      }

      if (mounted) {
        setState(() {
          _nights = combined;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Load Sessions error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Generate realistic demo data matching your screenshots for May 18-23
  List<Map<String, dynamic>> _generateRealisticDemoSessions() {
    final demoSessions = <Map<String, dynamic>>[];
    
    // Data based on your screenshots (May 18-23, 2026)
    final List<Map<String, dynamic>> sleepData = [
      {
        'date': DateTime(2026, 5, 23),
        'start_hour': 22, 'start_min': 51,
        'end_hour': 4, 'end_min': 49,
        'total_sleep_min': 298, // 4h 58m
        'score': 59,
        'efficiency': 65,
        'deep_sleep': 72,   // 1h 12m
        'light_sleep': 181, // 3h 01m
        'rem_sleep': 45,    // 0h 45m
        'latency': 12,
        'waso': 28,
      },
      {
        'date': DateTime(2026, 5, 22),
        'start_hour': 22, 'start_min': 11,
        'end_hour': 7, 'end_min': 20,
        'total_sleep_min': 549, // 9h 09m
        'score': 91,
        'efficiency': 88,
        'deep_sleep': 56,   // 0h 56m
        'light_sleep': 341, // 5h 41m
        'rem_sleep': 152,   // 2h 32m
        'latency': 8,
        'waso': 15,
      },
      {
        'date': DateTime(2026, 5, 21),
        'start_hour': 23, 'start_min': 22,
        'end_hour': 6, 'end_min': 21,
        'total_sleep_min': 419, // 6h 59m
        'score': 94,
        'efficiency': 85,
        'deep_sleep': 118,  // 1h 58m
        'light_sleep': 239, // 3h 59m
        'rem_sleep': 62,    // 1h 02m
        'latency': 10,
        'waso': 18,
      },
      {
        'date': DateTime(2026, 5, 20),
        'start_hour': 23, 'start_min': 9,
        'end_hour': 7, 'end_min': 39,
        'total_sleep_min': 510, // 8h 30m
        'score': 85,
        'efficiency': 82,
        'deep_sleep': 48,   // 0h 48m
        'light_sleep': 228, // 3h 48m
        'rem_sleep': 234,   // 3h 54m
        'latency': 15,
        'waso': 22,
      },
      {
        'date': DateTime(2026, 5, 19),
        'start_hour': 23, 'start_min': 15,
        'end_hour': 6, 'end_min': 53,
        'total_sleep_min': 458, // 7h 38m
        'score': 94,
        'efficiency': 89,
        'deep_sleep': 102,  // 1h 42m
        'light_sleep': 145, // 2h 25m
        'rem_sleep': 211,   // 3h 31m
        'latency': 9,
        'waso': 12,
      },
      {
        'date': DateTime(2026, 5, 18),
        'start_hour': 23, 'start_min': 10,
        'end_hour': 5, 'end_min': 22,
        'total_sleep_min': 372, // 6h 12m
        'score': 44,
        'efficiency': 62,
        'deep_sleep': 45,
        'light_sleep': 180,
        'rem_sleep': 147,
        'latency': 19,
        'waso': 56,
      },
    ];
    
    for (int i = 0; i < sleepData.length; i++) {
      final data = sleepData[i];
      final date = data['date'] as DateTime;
      
      final startTime = DateTime(date.year, date.month, date.day, data['start_hour'], data['start_min']);
      final endTime = DateTime(date.year, date.month, date.day + 1, data['end_hour'], data['end_min']);
      
      final totalSleepMin = data['total_sleep_min'] as int;
      final score = (data['score'] as int).toDouble();
      final efficiency = (data['efficiency'] as int).toDouble();
      final latency = (data['latency'] as int).toDouble();
      final waso = (data['waso'] as int).toDouble();
      
      demoSessions.add({
        'session_id': 1000 + i,
        'start_time_ms': startTime.millisecondsSinceEpoch,
        'end_time_ms': endTime.millisecondsSinceEpoch,
        'sleep_score': score,
        'efficiency': efficiency,
        'tst': totalSleepMin.toDouble(),
        'tib': (totalSleepMin + latency + waso).toDouble(),
        'latency': latency,
        'waso': waso,
        'needs_recalc': false,
        // Additional fields for detailed sleep stages
        'deep_sleep_min': data['deep_sleep'],
        'light_sleep_min': data['light_sleep'],
        'rem_sleep_min': data['rem_sleep'],
      });
    }
    
    return demoSessions;
  }

  // Original demo generation (kept for compatibility)
  List<Map<String, dynamic>> _generateDemoSessions() {
    final demoSessions = <Map<String, dynamic>>[];
    final now = DateTime.now();
    
    final scores = [78, 82, 71, 88, 75, 84, 69, 91, 76, 80];
    final durations = [410, 435, 385, 465, 400, 445, 365, 480, 420, 455];
    final efficiencies = [82, 88, 76, 92, 80, 86, 73, 94, 84, 90];
    final latencies = [25, 18, 32, 12, 28, 15, 35, 10, 22, 14];
    final wasoValues = [45, 30, 52, 25, 42, 33, 58, 20, 38, 28];
    
    for (int i = 0; i < 10; i++) {
      final date = DateTime(now.year, now.month, now.day - i);
      
      final startHour = 22;
      final startMinute = 15 + (i % 4) * 5;
      final endHour = 6;
      final endMinute = 15 + (i % 6) * 5;
      
      final startTime = DateTime(date.year, date.month, date.day, startHour, startMinute);
      final endTime = DateTime(date.year, date.month, date.day + 1, endHour, endMinute);
      
      final sleepMinutes = durations[i % durations.length];
      final score = scores[i % scores.length];
      final efficiency = efficiencies[i % efficiencies.length];
      
      demoSessions.add({
        'session_id': 1000 + i,
        'start_time_ms': startTime.millisecondsSinceEpoch,
        'end_time_ms': endTime.millisecondsSinceEpoch,
        'sleep_score': score.toDouble(),
        'efficiency': efficiency.toDouble(),
        'tst': sleepMinutes.toDouble(),
        'tib': (sleepMinutes + 30).toDouble(),
        'latency': latencies[i % latencies.length].toDouble(),
        'waso': wasoValues[i % wasoValues.length].toDouble(),
        'needs_recalc': false,
      });
    }
    
    return demoSessions;
  }

  // Fix existing sessions with incorrect end times
  Future<void> _fixExistingSessions() async {
    final db = await AppDb.db;
    final sessions = await db.query('sessions');
    int fixedCount = 0;
    
    for (final session in sessions) {
      final sessionId = session['session_id'] as int;
      final startMs = session['start_time_ms'] as int;
      final currentEndMs = session['end_time_ms'] as int?;
      
      final now = DateTime.now().millisecondsSinceEpoch;
      final isInvalid = currentEndMs == null || 
          currentEndMs > now || 
          currentEndMs < startMs ||
          currentEndMs > startMs + (16 * 60 * 60 * 1000);
      
      if (isInvalid) {
        final fixedEndMs = startMs + (8 * 60 * 60 * 1000);
        
        await db.update(
          'sessions',
          {'end_time_ms': fixedEndMs},
          where: 'session_id = ?',
          whereArgs: [sessionId],
        );
        
        await _processSessionLogic(sessionId);
        fixedCount++;
      }
    }
    
    await _loadSessions();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Fixed $fixedCount sessions with incorrect end times"),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // Toggle between demo and real mode
  void _toggleDemoMode() {
    setState(() {
      _demoMode = !_demoMode;
      _loadSessions();
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_demoMode ? "Demo Mode ON - Showing realistic May 18-23 data" : "Real Data Mode ON"),
        backgroundColor: _demoMode ? Colors.orange : Colors.green,
      ),
    );
  }

  int _parseSessionId(dynamic rawId) {
    return rawId is int ? rawId : int.parse(rawId.toString());
  }

  Future<Map<String, dynamic>?> _getSummaryForSession(dynamic db, int sessionId) async {
    try {
      final summaryRows = await db.query(
        'sleep_summaries',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      return summaryRows.isNotEmpty ? summaryRows.first : null;
    } catch (e) {
      debugPrint("Summary error for session $sessionId: $e");
      return null;
    }
  }

  Map<String, dynamic> _buildSessionData(
    Map<String, dynamic> session,
    int sessionId,
    Map<String, dynamic>? summary,
  ) {
    return {
      'id': sessionId,
      'session_id': sessionId,
      'start_time_ms': session['start_time_ms'],
      'end_time_ms': session['end_time_ms'] ?? DateTime.now().millisecondsSinceEpoch,
      'efficiency': (summary?['sleep_efficiency_pct'] ?? 0.0).toDouble(),
      'sleep_score': (summary?['sleep_score'] ?? 0.0).toDouble(),
      'tst': (summary?['total_sleep_time_min'] ?? 0.0).toDouble(),
      'tib': (summary?['time_in_bed_min'] ?? 0.0).toDouble(),
      'latency': (summary?['sleep_latency_min'] ?? 0.0).toDouble(),
      'waso': (summary?['waso_min'] ?? 0.0).toDouble(),
      'needs_recalc': summary == null,
    };
  }

  // ==================== SESSION PROCESSING ====================

  Future<void> _processSessionLogic(int sessionId) async {
    final blocks = await AppDb.get5sBlocksForSession(sessionId);

    final scoredEpochs = blocks.isNotEmpty
        ? SleepScorer.scoreRows(
            blocks,
            algorithm: SleepAlgorithm.sadehScaledConvolved,
            activityScale: 0.1,
          )
        : SleepScorer.scoreRows(
            await AppDb.getSamplesForSession(sessionId),
            algorithm: SleepAlgorithm.sadehScaledConvolved,
            activityScale: 0.1,
          );

    if (scoredEpochs.isEmpty) return;

    final metrics = SleepScorer.calculateMetrics(scoredEpochs);
    final sleepScore = SleepScorer.calculateSleepScore(metrics);

    await AppDb.upsertSleepSummary(
      sessionId: sessionId,
      timeInBedMin: metrics.timeInBedMinutes,
      totalSleepTimeMin: metrics.totalSleepTimeMinutes,
      sleepLatencyMin: metrics.sleepLatencyMinutes,
      wasoMin: metrics.wasoMinutes,
      sleepEfficiencyPct: metrics.sleepEfficiency,
      sleepOnsetMs: metrics.sleepOnsetMs,
      finalWakeMs: metrics.finalWakeMs,
      sleepScore: sleepScore,
    );

    await AppDb.replaceScoredEpochs(
      sessionId: sessionId,
      rows: scoredEpochs.map((e) => {
        'epoch_start_ms': e.startMs,
        'epoch_end_ms': e.endMs,
        'activity': e.activity,
        'scaled_activity': e.scaledActivity,
        'conv_activity': e.convolvedActivity,
        'mean_hr': e.meanHr,
        'sadeh_score': e.sadehScore,
        'label': e.isSleep ? 'sleep' : 'wake',
      }).toList(),
    );
  }

  Future<void> _recalculateSession(int sessionId) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await _processSessionLogic(sessionId);
      await _loadSessions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Analysis Complete!"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint("Recalc error: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _recalculateAllSessions() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final db = await AppDb.db;
      final sessions = await db.query('sessions');

      for (final session in sessions) {
        await _processSessionLogic(session['session_id'] as int);
      }

      await _loadSessions();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("All sessions optimized!"), backgroundColor: Colors.cyan),
        );
      }
    } catch (e) {
      debugPrint("Recalculate ALL error: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ==================== EXPORT ====================

  Future<void> _exportSingleSession(Map<String, dynamic> session) async {
    final sessionId = session['session_id'];

    try {
      final scoredEpochs = await AppDb.getScoredEpochsForSession(sessionId);

      if (scoredEpochs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("No data to export for this session"),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final csvContent = _buildCsvContent(scoredEpochs);
      final fileName = _buildFileName(session);
      final file = await _saveCsvFile(fileName, csvContent);

      if (await file.exists()) {
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Sleep Session #$sessionId - ${_getDateString(session)}',
          text: 'Export of sleep session from ${_formatDate(session['start_time_ms'] as int)}',
        );
      }
    } catch (e) {
      debugPrint("Export session error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Export failed: $e"), backgroundColor: Colors.red),
      );
    }
  }

  String _buildCsvContent(List<Map<String, dynamic>> scoredEpochs) {
    final sb = StringBuffer();
    sb.writeln("epoch_start,epoch_end,activity,scaled_activity,conv_activity,mean_hr,sadeh_score,label");

    for (int i = 0; i < scoredEpochs.length; i++) {
      final e = scoredEpochs[i];
      final epochStartNum = _baseEpoch + (i * _epochStep);
      final epochEndNum = _baseEpoch + ((i + 1) * _epochStep);

      sb.writeln(
        "$epochStartNum,$epochEndNum,${e['activity'] ?? 0},${e['scaled_activity'] ?? 0.0},"
        "${e['conv_activity'] ?? 0.0},${e['mean_hr'] ?? 0},${e['sadeh_score'] ?? 0.0},${e['label'] ?? 'wake'}",
      );
    }

    return sb.toString();
  }

  String _buildFileName(Map<String, dynamic> session) {
    final startMs = session['start_time_ms'] as int;
    final date = DateTime.fromMillisecondsSinceEpoch(startMs);
    final dateStr = "${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}";
    return "i_sleep_session_${session['session_id']}_$dateStr.csv";
  }

  String _getDateString(Map<String, dynamic> session) {
    final startMs = session['start_time_ms'] as int;
    final date = DateTime.fromMillisecondsSinceEpoch(startMs);
    return "${date.year}-${date.month}-${date.day}";
  }

  Future<File> _saveCsvFile(String fileName, String content) async {
    final dir = await getTemporaryDirectory();
    final file = File("${dir.path}/$fileName");
    await file.writeAsString(content);
    return file;
  }

  // ==================== DELETE ====================

  Future<void> _deleteSession(int sessionId) async {
    final confirmDeletion = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Delete Recording?"),
            content: const Text("This will permanently remove this sleep session."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("CANCEL"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("DELETE", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ??
        false;

    if (confirmDeletion) {
      setState(() => _isLoading = true);
      await AppDb.deleteSession(sessionId);
      await _loadSessions();
    }
  }

  // ==================== UI HELPERS ====================

  Color _getScoreColor(double score) {
    if (score >= 85) return _scoreColorExcellent;
    if (score >= 70) return _scoreColorGood;
    if (score >= 50) return _scoreColorPoor;
    return _scoreColorVeryPoor;
  }

  int _parseTimestamp(dynamic val) {
    if (val == null) return 0;
    if (val is int) return val;
    return int.tryParse(val.toString()) ?? 0;
  }

  String _formatDate(int ms) {
    if (ms == 0) return "Unknown Date";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return "${dt.day} ${months[dt.month - 1]} ${dt.year}";
  }

  String _formatTime(int ms) {
    if (ms == 0) return "--:--";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  String _formatDuration(double minutes) {
    if (minutes <= 0) return "0m";
    final hours = (minutes / 60).floor();
    final mins = (minutes % 60).toInt();
    return hours > 0 ? "${hours}h ${mins}m" : "${mins}m";
  }

  // ==================== UI WIDGETS ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      leading: _buildBackButton(),
      title: GestureDetector(
        onLongPress: _toggleDemoMode,  // Long press title to toggle demo mode
        child: const Text(
          "Sleep Journal",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      actions: [
        IconButton(
          icon: _isProcessing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.cyanAccent,
                  ),
                )
              : const Icon(Icons.auto_awesome, color: Colors.cyanAccent),
          tooltip: "Optimize All",
          onPressed: _isProcessing ? null : _recalculateAllSessions,
        ),
      ],
    );
  }

  Widget? _buildBackButton() {
    if (!Navigator.canPop(context)) return null;
    return IconButton(
      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
    }

    if (_nights.isEmpty) {
      return _buildNoDataCard();
    }

    return RefreshIndicator(
      onRefresh: _loadSessions,
      color: Colors.cyanAccent,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _nights.length,
        itemBuilder: (context, index) => _buildCard(_nights[index]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> session) {
    final startVal = _parseTimestamp(session['start_time_ms']);
    final endVal = _parseTimestamp(session['end_time_ms']);
    final efficiency = session['efficiency'];
    final sleepScore = session['sleep_score'];
    final needsRecalc = session['needs_recalc'] ?? false;
    final themeColor = needsRecalc ? Colors.orangeAccent : _getScoreColor(sleepScore);
    final sessionId = session['session_id'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        leading: Icon(Icons.circle, color: themeColor, size: 12),
        title: Text(
          _formatDate(startVal),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF3F3B76),
            fontSize: 17,
          ),
        ),
        subtitle: Text(
          "${_formatTime(startVal)} - ${_formatTime(endVal)}",
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        trailing: _buildCardActions(session, needsRecalc, sleepScore, themeColor, sessionId),
        children: [
          _buildCardContent(session, needsRecalc, efficiency, sleepScore, themeColor, sessionId),
        ],
      ),
    );
  }

  Widget _buildCardActions(
    Map<String, dynamic> session,
    bool needsRecalc,
    double sleepScore,
    Color themeColor,
    int sessionId,
  ) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        Text(
          needsRecalc ? "NEW" : "${sleepScore.round()}",
          style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        IconButton(
          icon: const Icon(Icons.share_outlined, color: Colors.blueAccent, size: 20),
          onPressed: () => _exportSingleSession(session),
          tooltip: "Export this session",
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
          onPressed: () => _deleteSession(sessionId),
        ),
      ],
    );
  }

  Widget _buildCardContent(
    Map<String, dynamic> session,
    bool needsRecalc,
    double efficiency,
    double sleepScore,
    Color themeColor,
    int sessionId,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        children: [
          const Divider(),
          if (needsRecalc) ...[
            _buildRecalcContent(sessionId),
          ] else ...[
            _buildAnalyzedContent(session, efficiency, sleepScore, themeColor),
          ],
        ],
      ),
    );
  }

  Widget _buildRecalcContent(int sessionId) {
    return Column(
      children: [
        const SizedBox(height: 10),
        const Text(
          "Session recorded. Tap below to calculate your score.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black87, fontSize: 13),
        ),
        const SizedBox(height: 15),
        ElevatedButton.icon(
          onPressed: _isProcessing ? null : () => _recalculateSession(sessionId),
          icon: _isProcessing
              ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.analytics_outlined),
          label: const Text("Refresh"),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color.from(alpha: 1, red: 0.361, green: 0.329, blue: 0.678),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 45),
          ),
        ),
      ],
    );
  }

  Widget _buildAnalyzedContent(
    Map<String, dynamic> session,
    double efficiency,
    double sleepScore,
    Color themeColor,
  ) {
    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildMetricItem("Score", "${sleepScore.round()}"),
            _buildMetricItem("Efficiency", "${efficiency.round()}%"),
          ],
        ),
        const SizedBox(height: 15),
        Text(
          _formatDuration(session['tst']),
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: themeColor),
        ),
        const Text("Total Sleep Time", style: TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildMetricItem("Latency", "${session['latency'].toInt()}m"),
            _buildMetricItem("Awake", _formatDuration(session['waso'])),
            _buildMetricItem("In Bed", _formatDuration(session['tib'])),
          ],
        ),
        const SizedBox(height: 25),
        _buildViewBreakdownButton(session),
      ],
    );
  }

  Widget _buildMetricItem(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3F3B76), fontSize: 15)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }

  Widget _buildViewBreakdownButton(Map<String, dynamic> session) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF5C54AD),
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: () {
        if (widget.onSessionTap != null) widget.onSessionTap!(session);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HistoryScreen(
              initialSession: session,
              onBarTapped: (data) {},
            ),
          ),
        );
      },
      child: const Text("View Full Breakdown", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
    );
  }

  Widget _buildNoDataCard() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bedtime_outlined, size: 64, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: 16),
          const Text(
            "No sleep recordings found",
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _toggleDemoMode,
            child: const Text("Tap to enable Demo Mode", style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }
}