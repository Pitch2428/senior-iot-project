import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:math' as math;
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
        activityScale: 0.1, 
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        elevation: 0, 
        automaticallyImplyLeading: false, 
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
        : RefreshIndicator(
            onRefresh: _loadData,
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
        child: Text("No Data for this Date", style: TextStyle(color: Colors.white54))
      );
    }
    final session = _selectedSession ?? _filteredSessions.first;

    return Column(
      children: [
        _buildMetricGrid(session),
        const SizedBox(height: 30),
        _buildTimelineSection(),
        const SizedBox(height: 30),
        _buildSessionList(),
      ],
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
        IconButton(icon: const Icon(Icons.calendar_month, color: Colors.white), onPressed: () async {
          final picked = await showDatePicker(
            context: context, 
            initialDate: selectedDate, 
            firstDate: DateTime(2024), 
            lastDate: DateTime.now()
          );
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
    final lat = (s['sleep_latency_min'] as num? ?? 0).toDouble(); // ADDED Latency
    final tib = (s['time_in_bed_min'] as num? ?? (tst + waso + lat)).toDouble();

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
        _metric("Efficiency", "${eff.toStringAsFixed(1)}%"),
        _metric("Total Sleep", _formatDuration(tst)),
        _metric("Latency", _formatDuration(lat)), // NEW UI ITEM
        _metric("WASO", _formatDuration(waso)),
        _metric("Fell Asleep", formatClock(s['sleep_onset_ms'])),
        _metric("Woke Up", formatClock(s['final_wake_ms'])),
      ],
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _buildTimelineSection() {
    if (_currentEpochs.isEmpty) return const SizedBox.shrink();
    
    const double epochWidth = 3.5; 
    final double chartWidth = _currentEpochs.length * epochWidth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Sleep Timeline", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
        const SizedBox(height: 15),
        Container(
          height: 160, 
          width: double.infinity,
          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: chartWidth,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(
                  painter: HypnogramPainter(epochs: _currentEpochs, stepWidth: epochWidth),
                ),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8.0),
          child: Center(
            child: Text("← Scroll to see timeline →", style: TextStyle(color: Colors.white24, fontSize: 10, fontStyle: FontStyle.italic)),
          ),
        )
      ],
    );
  }

  Widget _buildSessionList() {
    return Column(children: [
      const Divider(color: Colors.white10, height: 40),
      ..._filteredSessions.map((s) {
        final id = s['session_id'] ?? s['id'];
        final isSelected = (_selectedSession?['session_id'] ?? _selectedSession?['id']) == id;
        return ListTile(
          onTap: () => _loadAnalysisForSession(s),
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.nights_stay_outlined, color: isSelected ? Colors.cyanAccent : Colors.white24),
          title: Text("Session #$id", style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontSize: 14)),
          trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white10, size: 14),
        );
      }),
    ]);
  }

  Widget _buildWeekContent() {
    final now = DateTime.now();
    final last7Days = List.generate(7, (i) => DateTime(now.year, now.month, now.day).subtract(Duration(days: i))).reversed.toList();

    Map<String, double> dailySleep = {};
    for (var date in last7Days) {
      dailySleep[DateFormat('yyyy-MM-dd').format(date)] = 0.0;
    }

    for (var s in _allSessions) {
      final dynamic rawTs = s['start_time_ms'] ?? s['sleep_onset_ms'] ?? 0;
      final int ts = rawTs is int ? rawTs : int.parse(rawTs.toString());
      if (ts == 0) continue;
      
      final dateKey = DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts));
      if (dailySleep.containsKey(dateKey)) {
        dailySleep[dateKey] = dailySleep[dateKey]! + (s['total_sleep_time_min'] as num? ?? 0).toDouble();
      }
    }

    double totalMinutes = dailySleep.values.fold(0, (sum, item) => sum + item);
    double avgMin = totalMinutes / 7;
    double maxSleep = dailySleep.values.fold(480.0, (max, v) => v > max ? v : max);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _weeklyStat("Avg. Sleep", _formatDuration(avgMin)),
              Container(width: 1, height: 30, color: Colors.white10),
              _weeklyStat("Days Tracked", "${dailySleep.values.where((v) => v > 0).length}/7"),
            ],
          ),
        ),
        const SizedBox(height: 40),
        SizedBox(
          height: 200,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: last7Days.map((date) {
              final dateKey = DateFormat('yyyy-MM-dd').format(date);
              final double tst = dailySleep[dateKey] ?? 0.0;
              final double barHeight = (tst / maxSleep).clamp(0.02, 1.0) * 140;
              final bool isLow = tst < 360 && tst > 0;

              return Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FittedBox(child: Text(tst == 0 ? "-" : _formatDuration(tst), style: TextStyle(color: tst == 0 ? Colors.white24 : (isLow ? Colors.orangeAccent : Colors.cyanAccent), fontSize: 8, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 6),
                    Container(
                      width: 20,
                      height: barHeight, 
                      decoration: BoxDecoration(
                        color: tst == 0 ? Colors.white.withOpacity(0.05) : null,
                        gradient: tst == 0 ? null : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            isLow ? Colors.orangeAccent : Colors.cyanAccent,
                            isLow ? Colors.orangeAccent.withOpacity(0.2) : Colors.cyanAccent.withOpacity(0.1),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(4)
                      ),
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
    );
  }

  Widget _weeklyStat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
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

    // --- FIXED GRAPH TIME LOGIC ---
    for (int i = 0; i < epochs.length; i++) {
      DateTime dt = DateTime.fromMillisecondsSinceEpoch(epochs[i].timestamp);
      
      // Check for start of hour (minute 0) OR if it's the very first epoch
      if ((dt.minute == 0 && dt.second < 31) || i == 0) {
        double x = i * stepWidth;
        
        // Vertical grid line
        canvas.drawLine(Offset(x, 0), Offset(x, labelY), linePaint);
        
        // Time Label
        textPainter.text = TextSpan(
          text: DateFormat('HH:mm').format(dt),
          style: const TextStyle(color: Colors.white38, fontSize: 9),
        );
        textPainter.layout();
        
        // Prevent label from being cut off at the start
        double xOffset = (i == 0) ? x : x - (textPainter.width / 2);
        textPainter.paint(canvas, Offset(xOffset, labelY + 4));
      }
    }

    // Draw Hypnogram Path
    final Path sleepPath = Path();
    final Paint sleepPaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
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

    // Draw Wake Markers
    final Paint wakeMarkerPaint = Paint()..color = Colors.orangeAccent;
    for (int i = 0; i < epochs.length; i++) {
      if (!epochs[i].isSleep) {
        canvas.drawRect(Rect.fromLTWH(i * stepWidth, wakeY - 3, stepWidth, 6), wakeMarkerPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant HypnogramPainter oldDelegate) => 
      oldDelegate.epochs.length != epochs.length;
}