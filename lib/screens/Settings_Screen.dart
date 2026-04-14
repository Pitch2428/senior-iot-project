import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import '../Database/AppDb.dart';
import 'Welcome_Page.dart'; 

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _name = "User";
  String _gender = "Male";
  int _age = 20;
  int _weight = 60;
  int _height = 150;

  @override
  void initState() {
    super.initState();
    _loadProfile();
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

  // --- EXPORT LOGIC (Matching the Recording Screen) ---
Future<void> _exportByDate() async {
  final DateTime? picked = await showDatePicker(
    context: context,
    initialDate: DateTime.now(),
    firstDate: DateTime(2024),
    lastDate: DateTime.now(),
  );

  if (picked == null) return;

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
  final rows = await AppDb.getSamplesForSession(sessionId);

  if (rows.isEmpty) return;

  final sb = StringBuffer();
  sb.writeln("Timestamp_MS,Time_Local,HR_BPM,Acc_X,Acc_Y,Acc_Z");

  for (var r in rows) {
    final ts = (r['timestamp_ms'] as num).toInt();
    final timeStr = DateFormat('HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(ts));

    sb.writeln(
      "$ts,$timeStr,${r['hr_bpm']},${r['acc_x']},${r['acc_y']},${r['acc_z']}",
    );
  }

  final directory = await getTemporaryDirectory();
  final file = File(
    "${directory.path}/session_${sessionId}_${picked.year}_${picked.month}_${picked.day}.csv",
  );

  await file.writeAsString(sb.toString());

  await Share.shareXFiles(
    [XFile(file.path)],
    text: "Sleep session export",
  );
}

  void _editProfileAndReset() async {
    bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit Profile Info"),
        content: const Text("This will return you to the registration screen. History is preserved."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
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
        title: const Text("Reset All Data?"),
        content: const Text("This permanently deletes all sessions. This cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text("Wipe", style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AppDb.clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Database wiped successfully"))
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
        child: Column(
          children: [
            _buildCard(
              title: "Profile",
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildProfileRow("Name", _name),
                  _buildProfileRow("Gender", _gender),
                  _buildProfileRow("Age", "$_age"),
                  _buildProfileRow("Weight", "$_weight kg"),
                  _buildProfileRow("Height", "$_height cm"),
                  const SizedBox(height: 20),
                  _buildActionButton("Edit Profile Info", const Color(0xFF9086FF), _editProfileAndReset),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildCard(
              title: "Dataset (Raw Storage)",
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Export raw epoch data for analysis:", style: TextStyle(color: Colors.black54, fontSize: 13)),
                  const SizedBox(height: 20),
                  _buildActionButton("Export Data by Date", const Color(0xFF9086FF), _exportByDate),
                  const SizedBox(height: 10),
                  _buildOutlineButton("Wipe Database (Reset All)", Colors.redAccent, _wipeDatabase),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildCard(
              title: "About i-Sleep",
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAboutRow("TST", "Total sum of 30s epochs predicted as \"Sleep\"."),
                  _buildAboutRow("SE", "Percentage of time asleep vs. time in bed."),
                  _buildAboutRow("WASO", "Total wake time after the initial onset of sleep."),
                  const SizedBox(height: 20),
                  const Text("Model Version: sadeh_v1_2025", 
                    style: TextStyle(color: Color(0xFF9086FF), fontSize: 10, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF3F3B76))),
          const Divider(height: 30),
          child,
        ],
      ),
    );
  }

  Widget _buildProfileRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Text("$label: ", style: const TextStyle(color: Colors.black38, fontSize: 14)),
        Text(value, style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _buildAboutRow(String term, String definition) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.black54, fontSize: 13, height: 1.4),
          children: [
            TextSpan(text: "$term: ", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
            TextSpan(text: definition),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback onPressed) {
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
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ),
    );
  }
}