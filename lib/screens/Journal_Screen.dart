import 'package:flutter/material.dart';
import '../Database/AppDb.dart'; 
import '../screens/history_screen.dart'; 
import '../logic/sadeh.dart'; 

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

  Future<void> _loadSessions() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final db = await AppDb.db;
      final List<Map<String, dynamic>> sessions = await db.query('sessions', orderBy: 'start_time_ms DESC');

      List<Map<String, dynamic>> combined = [];

      for (var s in sessions) {
        final dynamic rawId = s['session_id'];
        final int sessionId = rawId is int ? rawId : int.parse(rawId.toString());
        
        Map<String, dynamic>? summary;
        try {
          final summaryRows = await db.query(
            'sleep_summaries',
            where: 'session_id = ?',
            whereArgs: [sessionId],
          );
          if (summaryRows.isNotEmpty) summary = summaryRows.first;
        } catch (e) {
          debugPrint("Summary error for session $sessionId: $e");
        }

        combined.add({
          'id': sessionId,
          'session_id': sessionId,
          'start_time_ms': s['start_time_ms'], 
          'end_time_ms': s['end_time_ms'] ?? DateTime.now().millisecondsSinceEpoch,
          'efficiency': (summary?['sleep_efficiency_pct'] ?? 0.0).toDouble(),
          'tst': (summary?['total_sleep_time_min'] ?? 0.0).toDouble(),
          'tib': (summary?['time_in_bed_min'] ?? 0.0).toDouble(),
          'latency': (summary?['sleep_latency_min'] ?? 0.0).toDouble(),
          'waso': (summary?['waso_min'] ?? 0.0).toDouble(),
          // FIX: Only mark as "NEW" if the summary record is physically missing from DB
          'needs_recalc': summary == null, 
        });
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

  Future<void> _processSessionLogic(int sessionId) async {
    final blocks = await AppDb.get5sBlocksForSession(sessionId);
    
    // Use the unified scoreRows method
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

    // Ensure database write completes
    await AppDb.upsertSleepSummary(
      sessionId: sessionId,
      timeInBedMin: metrics.timeInBedMinutes,
      totalSleepTimeMin: metrics.totalSleepTimeMinutes,
      sleepLatencyMin: metrics.sleepLatencyMinutes,
      wasoMin: metrics.wasoMinutes,
      sleepEfficiencyPct: metrics.sleepEfficiency,
      sleepOnsetMs: metrics.sleepOnsetMs,
      finalWakeMs: metrics.finalWakeMs,
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
      // Force UI reload immediately after logic completes
      await _loadSessions(); 
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Analysis Complete!"), backgroundColor: Colors.green)
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

      for (final s in sessions) {
        await _processSessionLogic(s['session_id'] as int);
      }
      
      await _loadSessions();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("All sessions optimized!"), backgroundColor: Colors.cyan)
        );
      }
    } catch (e) {
      debugPrint("Recalculate ALL error: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _deleteSession(int sessionId) async {
    final bool confirmDeletion = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Recording?"),
        content: const Text("This will permanently remove this sleep session."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("CANCEL")),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text("DELETE", style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    ) ?? false;

    if (confirmDeletion) {
      setState(() => _isLoading = true);
      final db = await AppDb.db;
      await db.transaction((txn) async {
        await txn.delete('samples', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('raw_5s_blocks', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('sleep_summaries', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('sessions', where: 'session_id = ?', whereArgs: [sessionId]);
      });
      await _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: _isProcessing 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent))
              : const Icon(Icons.auto_awesome, color: Colors.cyanAccent),
            tooltip: "Optimize All",
            onPressed: _isProcessing ? null : _recalculateAllSessions,
          ),
        ],
        leading: Navigator.canPop(context) 
          ? IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            )
          : null, 
        title: const Text("Sleep Journal", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : _nights.isEmpty
              ? _buildNoDataCard()
              : RefreshIndicator(
                  onRefresh: _loadSessions,
                  color: Colors.cyanAccent,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _nights.length,
                    itemBuilder: (context, index) => _buildCard(_nights[index]),
                  ),
                ),
    );
  }

  Widget _buildCard(Map<String, dynamic> s) {
    final int startVal = _parseTimestamp(s['start_time_ms']);
    final int endVal = _parseTimestamp(s['end_time_ms']);
    final double eff = s['efficiency'];
    final bool needsRecalc = s['needs_recalc'] ?? false;
    final Color themeColor = needsRecalc ? Colors.orangeAccent : _getEfficiencyColor(eff);
    final int sessionId = s['session_id'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(24),
      ),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        leading: Icon(Icons.circle, color: themeColor, size: 12),
        title: Text(_formatDate(startVal), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3F3B76), fontSize: 17)),
        subtitle: Text("${_formatTime(startVal)} - ${_formatTime(endVal)}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(
              needsRecalc ? "NEW" : "${eff.round()}%", 
              style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 16)
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
              onPressed: () => _deleteSession(sessionId),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              children: [
                const Divider(),
                if (needsRecalc) ...[
                  const SizedBox(height: 10),
                  const Text("Session recorded. Tap below to calculate your score.", 
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, fontSize: 13)),
                  const SizedBox(height: 15),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : () => _recalculateSession(sessionId),
                    icon: _isProcessing 
                        ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.analytics_outlined),
                    label: const Text("ANALYZE NOW"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5C54AD), 
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 45)
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  Text(_formatDuration(s['tst']), style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: themeColor)),
                  const Text("Total Sleep Time", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _item("Latency", "${s['latency'].toInt()}m"),
                      _item("Awake", _formatDuration(s['waso'])),
                      _item("In Bed", _formatDuration(s['tib'])),
                    ],
                  ),
                  const SizedBox(height: 25),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5C54AD),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      if (widget.onSessionTap != null) widget.onSessionTap!(s);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => HistoryScreen(
                            initialSession: s,
                            onBarTapped: (data) {}, 
                          ),
                        ),
                      );
                    },
                    child: const Text("View Full Breakdown", style: TextStyle(fontWeight: FontWeight.bold)),
                  )
                ],
              ],
            ),
          )
        ],
      ),
    );
  }

  int _parseTimestamp(dynamic val) {
    if (val == null) return 0;
    if (val is int) return val;
    return int.tryParse(val.toString()) ?? 0;
  }

  String _formatDate(int ms) {
    if (ms == 0) return "Unknown Date";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return "${dt.day} ${months[dt.month-1]} ${dt.year}";
  }

  String _formatTime(int ms) {
    if (ms == 0) return "--:--";
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  String _formatDuration(double minutes) {
    if (minutes <= 0) return "0h 0m";
    int h = (minutes / 60).floor();
    int m = (minutes % 60).toInt();
    return h > 0 ? "${h}h ${m}m" : "${m}m";
  }

  Color _getEfficiencyColor(double eff) {
    if (eff >= 85) return Colors.green;
    if (eff >= 70) return Colors.blueAccent;
    if (eff >= 50) return Colors.orange;
    return Colors.red;
  }

  Widget _item(String label, String val) {
    return Column(children: [
      Text(val, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3F3B76))),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey))
    ]);
  }

  Widget _buildNoDataCard() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bedtime_outlined, size: 64, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 16),
          const Text("No sleep recordings found", style: TextStyle(color: Colors.white54, fontSize: 16)),
        ],
      ),
    );
  }
}