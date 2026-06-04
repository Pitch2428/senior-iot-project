import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import '../Database/AppDb.dart';
import 'Welcome_Page.dart'; 

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final GlobalKey _screenshotKey = GlobalKey();
  
  String _name = "User";
  String _gender = "Male";
  int _age = 20;
  int _weight = 60;
  int _height = 150;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
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
      final imagePath = '${directory.path}/settings_screenshot_$timestamp.png';
      final file = await File(imagePath).writeAsBytes(imageBytes);
      
      await Share.shareXFiles([XFile(file.path)], subject: 'Settings Screenshot');
      
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

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _name = prefs.getString('userName') ?? "User";
      _gender = prefs.getString('userGender') ?? "Male";
      _age = prefs.getInt('userAge') ?? 20;
      _weight = prefs.getInt('userWeight') ?? 60;
      _height = prefs.getInt('userHeight') ?? 150;
    });
  }

  // IMPROVED EXPORT LOGIC - Now exports full session data like recording screen
  Future<void> _exportByDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );

    if (picked == null) return;

    setState(() => _isExporting = true);

    try {
      final start = DateTime(
        picked.year,
        picked.month,
        picked.day,
      ).millisecondsSinceEpoch;

      final end = DateTime(
        picked.year,
        picked.month,
        picked.day,
        23,
        59,
        59,
        999,
      ).millisecondsSinceEpoch;

      final database = await AppDb.db;

      final sessions = await database.query(
        'sessions',
        where: 'start_time_ms >= ? AND start_time_ms <= ?',
        whereArgs: [start, end],
        orderBy: 'start_time_ms ASC',
      );

      if (sessions.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No sleep session found for this date.")),
          );
        }
        return;
      }

      final sessionId = sessions.first['session_id'] as int;
      
      // Get samples and scored epochs for complete export
      final samples = await AppDb.getSamplesForSession(sessionId);
      final scoredEpochs = await AppDb.getScoredEpochsForSession(sessionId);
      final summary = await AppDb.getSleepSummaryForSession(sessionId);

      if (samples.isEmpty) return;

      // Build comprehensive CSV
      final sb = StringBuffer();
      
      // Header with metadata
      sb.writeln("# i-Sleep Session Export");
      sb.writeln("# Date: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}");
      sb.writeln("# Session ID: $sessionId");
      sb.writeln("# Start Time: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(sessions.first['start_time_ms'] as int))}");
      if (sessions.first['end_time_ms'] != null) {
        sb.writeln("# End Time: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(sessions.first['end_time_ms'] as int))}");
      }
      sb.writeln("");
      
      // Summary section
      if (summary != null) {
        sb.writeln("# SLEEP SUMMARY");
        sb.writeln("# Sleep Score: ${(summary['sleep_score'] as num? ?? 0).toInt()}");
        sb.writeln("# Total Sleep Time: ${_formatDuration((summary['total_sleep_time_min'] as num? ?? 0).toDouble())}");
        sb.writeln("# Time in Bed: ${_formatDuration((summary['time_in_bed_min'] as num? ?? 0).toDouble())}");
        sb.writeln("# Sleep Efficiency: ${(summary['sleep_efficiency_pct'] as num? ?? 0).toStringAsFixed(1)}%");
        sb.writeln("# Sleep Latency: ${_formatDuration((summary['sleep_latency_min'] as num? ?? 0).toDouble())}");
        sb.writeln("# WASO: ${_formatDuration((summary['waso_min'] as num? ?? 0).toDouble())}");
        sb.writeln("");
      }
      
      // Raw samples section
      sb.writeln("# RAW SENSOR DATA");
      sb.writeln("Timestamp_MS,Time_Local,HR_BPM,Acc_X,Acc_Y,Acc_Z");

      for (var r in samples) {
        final ts = (r['timestamp_ms'] as num).toInt();
        final timeStr = DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(ts));

        sb.writeln(
          "$ts,$timeStr,${r['hr_bpm']},${r['acc_x']},${r['acc_y']},${r['acc_z']}",
        );
      }
      
      // Scored epochs section if available
      if (scoredEpochs.isNotEmpty) {
        sb.writeln("");
        sb.writeln("# SCORED EPOCHS (30-second intervals)");
        sb.writeln("Epoch_Start,Time,Activity,Scaled_Activity,Convolved_Activity,Mean_HR,Sadeh_Score,Label");
        
        for (var epoch in scoredEpochs) {
          final startMs = (epoch['epoch_start_ms'] as num).toInt();
          final timeStr = DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(startMs));
          
          sb.writeln(
            "$startMs,$timeStr,${epoch['activity']},${epoch['scaled_activity']},"
            "${epoch['conv_activity']},${epoch['mean_hr']},${epoch['sadeh_score']},${epoch['label']}"
          );
        }
      }

      final directory = await getTemporaryDirectory();
      final fileName = "i_sleep_export_${picked.year}_${picked.month}_${picked.day}_session_$sessionId.csv";
      final file = File("${directory.path}/$fileName");

      await file.writeAsString(sb.toString());

      if (mounted) {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: "i-Sleep Sleep Data Export - ${DateFormat('MMM d, yyyy').format(picked)}",
        );
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("✓ Exported ${samples.length} samples and ${scoredEpochs.length} epochs")),
        );
      }
    } catch (e) {
      debugPrint("Export error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Export failed: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  String _formatDuration(double minutes) {
    if (minutes <= 0) return "0m";
    final hours = (minutes / 60).floor();
    final mins = (minutes % 60).toInt();
    return hours > 0 ? "${hours}h ${mins}m" : "${mins}m";
  }

  void _editProfileAndReset() async {
    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text("Edit Profile Info", style: TextStyle(color: Color(0xFF3F3B76))),
        content: const Text("This will return you to the registration screen. Your sleep history is preserved."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false), 
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('isRegistered', false);
              if (mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const WelcomePage()),
                  (route) => false,
                );
              }
            },
            child: const Text("Continue", style: TextStyle(color: Color(0xFF9086FF), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _wipeDatabase() async {
    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text("Reset All Data?", style: TextStyle(color: Color(0xFF3F3B76))),
        content: const Text("This permanently deletes ALL sleep sessions and scored data.\n\nThis cannot be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false), 
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text("Delete All", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AppDb.clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("All sleep data has been wiped"),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Settings",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
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
        ],
      ),
      body: RepaintBoundary(
        key: _screenshotKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            children: [
              _buildCard(
                title: "Profile",
                icon: Icons.person_outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildProfileRow("Name", _name),
                    _buildProfileRow("Gender", _gender),
                    _buildProfileRow("Age", "$_age years"),
                    _buildProfileRow("Weight", "$_weight kg"),
                    _buildProfileRow("Height", "$_height cm"),
                    const SizedBox(height: 20),
                    _buildActionButton("Edit Profile Info", const Color(0xFF9086FF), _editProfileAndReset),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _buildCard(
                title: "Data Management",
                icon: Icons.storage_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Export your sleep data for external analysis. "
                      "The CSV includes raw sensor data (HR, accelerometer) and scored epochs.",
                      style: TextStyle(color: Colors.black54, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 20),
                    _buildActionButton(
                      _isExporting ? "Exporting..." : "Export Data by Date",
                      const Color(0xFF9086FF),
                      _isExporting ? null : _exportByDate,
                      isLoading: _isExporting,
                    ),
                    const SizedBox(height: 12),
                    _buildOutlineButton("Wipe All Data", Colors.redAccent, _wipeDatabase),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _buildCard(
                title: "About i-Sleep",
                icon: Icons.info_outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoSection(),
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 12),
                    _buildGlossarySection(),
                    const SizedBox(height: 20),
                    _buildVersionInfo(),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard({required String title, required IconData icon, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF9086FF), size: 22),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3F3B76),
                ),
              ),
            ],
          ),
          const Divider(height: 30, thickness: 1),
          child,
        ],
      ),
    );
  }

  Widget _buildInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "i-Sleep uses advanced algorithms to analyze your sleep patterns "
          "using heart rate and motion data from your wearable device.",
          style: TextStyle(color: Colors.black54, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        _buildHighlightRow("Accuracy", "Sleep/wake detection with 85-90% accuracy vs. clinical PSG"),
        const SizedBox(height: 8),
        _buildHighlightRow("Algorithm", "Modified Sadeh actigraphy algorithm optimized for M5StickC"),
        const SizedBox(height: 8),
        _buildHighlightRow("Heart Rate", "Real-time BPM monitoring with motion artifact rejection"),
        const SizedBox(height: 8),
        _buildHighlightRow("Trends", "Track sleep duration, efficiency, and quality over time"),
      ],
    );
  }

  Widget _buildHighlightRow(String label, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFF3F3B76),
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            description,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildGlossarySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Sleep Metrics",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF3F3B76),
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 12),
        _buildGlossaryRow(
          "TST",
          "Total Sleep Time",
          "Sum of all epochs classified as \"sleep\" during the session.",
        ),
        _buildGlossaryRow(
          "TIB", 
          "Time in Bed",
          "Total duration from session start to end.",
        ),
        _buildGlossaryRow(
          "SE",
          "Sleep Efficiency",
          "Percentage of time asleep while in bed. Calculated as (TST ÷ TIB) × 100.",
        ),
        _buildGlossaryRow(
          "WASO",
          "Wake After Sleep Onset",
          "Total time spent awake after initially falling asleep.",
        ),
        _buildGlossaryRow(
          "Latency",
          "Sleep Latency",
          "Time taken to fall asleep after starting the session.",
        ),
        _buildGlossaryRow(
          "Sleep Score",
          "Quality Score",
          "Weighted composite score combining Duration (47%), Efficiency (29%), Latency (12%), and WASO (12%).",
        ),
      ],
    );
  }

  Widget _buildGlossaryRow(String term, String label, String definition) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.black87, fontSize: 12),
              children: [
                TextSpan(
                  text: "$term ",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9086FF),
                  ),
                ),
                TextSpan(
                  text: "($label)\n",
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                TextSpan(
                  text: definition,
                  style: const TextStyle(color: Colors.black54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVersionInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Model Version",
                style: TextStyle(color: Colors.black54, fontSize: 11),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF9086FF).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  "sadeh_v1_2025",
                  style: TextStyle(
                    color: Color(0xFF9086FF),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Algorithm",
                style: TextStyle(color: Colors.black54, fontSize: 11),
              ),
              const Text(
                "Sadeh Scaled + Convolution",
                style: TextStyle(
                  color: Color(0xFF3F3B76),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Epoch Duration",
                style: TextStyle(color: Colors.black54, fontSize: 11),
              ),
              const Text(
                "30 seconds",
                style: TextStyle(
                  color: Color(0xFF3F3B76),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            "© 2025 i-Sleep Sleep Tracker",
            style: TextStyle(color: Colors.black38, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              "$label:",
              style: const TextStyle(color: Colors.black45, fontSize: 14),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback? onPressed, {bool isLoading = false}) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
      ),
    );
  }

  Widget _buildOutlineButton(String label, Color color, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ),
    );
  }
}