import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../Database/AppDb.dart';
import '../screens/history_screen.dart';
import '../logic/sadeh.dart';

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
            activityScale: 500.0,
          )
        : SleepScorer.scoreRows(
            await AppDb.getSamplesForSession(sessionId),
            algorithm: SleepAlgorithm.sadehScaledConvolved,
            activityScale: 500.0,
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
      title: const Text(
        "Sleep Journal",
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
          style: const TextStyle(fontSize: 12, color: Colors.grey),
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
          style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 16),
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
          style: TextStyle(color: Colors.black54, fontSize: 13),
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
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: themeColor),
        ),
        const Text("Total Sleep Time", style: TextStyle(fontSize: 12, color: Colors.grey)),
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
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3F3B76))),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
      child: const Text("View Full Breakdown", style: TextStyle(fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildNoDataCard() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bedtime_outlined, size: 64, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 16),
          const Text(
            "No sleep recordings found",
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ],
      ),
    );
  }
}