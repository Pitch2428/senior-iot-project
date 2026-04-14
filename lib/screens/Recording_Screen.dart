// ignore_for_file: unused_field

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart'; 
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../Database/AppDb.dart'; 
import '../logic/sadeh.dart'; 
import 'journal_screen.dart';

const nusServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const nusTxUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isStoppedByAction) async {}
}

String _getFormattedDate() {
  final now = DateTime.now();
  final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return "${months[now.month - 1]} ${now.day}, ${now.year}";
}

class BleHome extends StatefulWidget {
  const BleHome({super.key});
  @override
  State<BleHome> createState() => _BleHomeState();
}

class _BleHomeState extends State<BleHome> with SingleTickerProviderStateMixin {
  final _ble = FlutterReactiveBle();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  final Map<String, DiscoveredDevice> _found = {};
  String? _connectedDeviceId;
  final _lineBuffer = StringBuffer();

  late AnimationController _pulseController;

  String _status = "Disconnected";
  String _bpmMean = "--";
  String _conf = "Low";

  double _xAxis = 0.0, _yAxis = 0.0, _zAxis = 0.0;
  int _dbRows = 0;

  bool _isRecording = false;
  bool _isReconnecting = false;
  int? _sessionStartTime;
  int? _currentSessionId;

  final List<double> _hrHistory = [];
  final List<double> _motionHistory = [];
  final int _maxDataPoints = 50;

  Map<String, dynamic>? _latestSync;
  Future<void> _dbQueue = Future.value();

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    _refreshDbRows();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _startScan();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'i_sleep_channel',
        channelName: 'i-sleep Sleep Tracking',
        channelDescription: 'Maintains sensor connection during sleep',
        channelImportance: NotificationChannelImportance.MAX,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
        eventAction: ForegroundTaskEventAction.repeat(5000),
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: 'i-sleep Recording Active',
        notificationText: 'Monitoring vitals in the background...',
        callback: startCallback,
      );
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _pulseController.dispose();
    WakelockPlus.disable();
    FlutterForegroundTask.stopService();
    super.dispose();
  }

  void _handleIncoming(Uint8List bytes) {
    try {
      final chunk = utf8.decode(bytes, allowMalformed: true);
      _lineBuffer.write(chunk);

      final full = _lineBuffer.toString();
      if (!full.contains('\n')) return; 

      final parts = full.split(RegExp(r'\r?\n'));
      _lineBuffer.clear();
      _lineBuffer.write(parts.last);

      for (int i = 0; i < parts.length - 1; i++) {
        final line = parts[i].trim();
        if (line.isEmpty) continue;
        _updateRealtimeUI(line);

        if (_isRecording && _currentSessionId != null) {
          _dbQueue = _dbQueue.then((_) => _commitToDatabase(line)).catchError((e) {
            debugPrint("DB Sync Error: $e");
          });
        }
      }
    } catch (e) {
      debugPrint("BLE Decode Error: $e");
    }
  }

  void _updateRealtimeUI(String line) {
    final parts = line.split(',');
    if (parts.length < 5) return;
    if (!mounted) return;

    int hr = int.tryParse(parts[1]) ?? -1;
    double ax = double.tryParse(parts[2]) ?? 0.0;
    double ay = double.tryParse(parts[3]) ?? 0.0;
    double az = double.tryParse(parts[4]) ?? 0.0;
    double mag = sqrt(ax*ax + ay*ay + az*az);

    setState(() {
      _xAxis = ax; _yAxis = ay; _zAxis = az;
      _bpmMean = hr > 0 ? hr.toString() : "--";
      _conf = (hr > 40 && hr < 110) ? "High" : "Low";

      _hrHistory.add(hr > 0 ? hr.toDouble() : 0.0);
      if (_hrHistory.length > _maxDataPoints) _hrHistory.removeAt(0);

      _motionHistory.add(mag);
      if (_motionHistory.length > _maxDataPoints) _motionHistory.removeAt(0);

      if (hr > 0) {
        final now = DateTime.now();
        _latestSync = {
          'label': "Sensor Sync",
          'time': "${now.hour}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}",
          'val': "$hr BPM"
        };
      }
    });

    if (hr > 0) _pulseController.forward(from: 0.0);
  }

  Future<void> _commitToDatabase(String line) async {
    final parts = line.split(',');
    await AppDb.insertSample(
      sessionId: _currentSessionId!,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      hrBpm: int.tryParse(parts[1]) ?? 0,
      accX: double.tryParse(parts[2]) ?? 0.0,
      accY: double.tryParse(parts[3]) ?? 0.0,
      accZ: double.tryParse(parts[4]) ?? 0.0,
      raw: line,
    );
    _refreshDbRows();
  }

  Future<void> _refreshDbRows() async {
    final c = await AppDb.countSamples();
    if (mounted) setState(() => _dbRows = c);
  }

  void _saveSessionToJournal() async {
    setState(() => _isRecording = false); 
    WakelockPlus.disable();
    await FlutterForegroundTask.stopService();

    await _dbQueue;

    if (_currentSessionId == null) return;

    final currentSamples = await AppDb.getSamplesForSession(_currentSessionId!);
    if (currentSamples.isEmpty) {
      setState(() { _sessionStartTime = null; _currentSessionId = null; });
      return;
    }

    final scoredEpochs = SleepScorer.scoreRows(
      currentSamples,
      algorithm: SleepAlgorithm.sadehScaledConvolved,
      activityScale: 0.1, 
    );

    await AppDb.replaceScoredEpochs(
      sessionId: _currentSessionId!,
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

    final metrics = SleepScorer.calculateMetrics(scoredEpochs);

    await AppDb.upsertSleepSummary(
      sessionId: _currentSessionId!,
      timeInBedMin: metrics.timeInBedMinutes,
      totalSleepTimeMin: metrics.totalSleepTimeMinutes,
      sleepLatencyMin: metrics.sleepLatencyMinutes,
      wasoMin: metrics.wasoMinutes,
      sleepEfficiencyPct: metrics.sleepEfficiency,
      sleepOnsetMs: metrics.sleepOnsetMs,
      finalWakeMs: metrics.finalWakeMs,
    );

    await AppDb.endSession(sessionId: _currentSessionId!, endTimeMs: DateTime.now().millisecondsSinceEpoch);

    if (mounted) {
      setState(() { _sessionStartTime = null; _currentSessionId = null; });
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => JournalScreen(highlightDate: _getFormattedDate())),
      );
    }
  }

  Future<void> _startScan() async {
    await [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    setState(() { _status = "Scanning..."; _found.clear(); });
    _scanSub = _ble.scanForDevices(withServices: [Uuid.parse(nusServiceUuid)]).listen((d) {
      if (mounted) setState(() => _found[d.id] = d);
    }, onError: (e) => debugPrint("Scan error: $e"));
  }

  Future<void> _connect(String deviceId) async {
    await _scanSub?.cancel();
    setState(() => _status = "Connecting...");
    _connSub = _ble.connectToDevice(id: deviceId, connectionTimeout: const Duration(seconds: 10)).listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        try { await _ble.requestMtu(deviceId: deviceId, mtu: 185); } catch (_) {}
        setState(() { _status = "Connected"; _connectedDeviceId = deviceId; });
        final c = QualifiedCharacteristic(deviceId: deviceId, serviceId: Uuid.parse(nusServiceUuid), characteristicId: Uuid.parse(nusTxUuid));
        _notifySub?.cancel();
        _notifySub = _ble.subscribeToCharacteristic(c).listen((data) => _handleIncoming(Uint8List.fromList(data)));
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        setState(() => _status = "Disconnected");
        if (_isRecording && _connectedDeviceId != null && !_isReconnecting) {
          _isReconnecting = true;
          Future.delayed(const Duration(seconds: 3), () { _connect(_connectedDeviceId!); _isReconnecting = false; });
        }
      }
    });
  }

  // INTEGRATED IMPROVED EXPORT LOGIC
  Future<void> _exportCsv() async {
    try {
      final List<Map<String, dynamic>> rawData = await AppDb.getAllScoredEpochs(); 
      if (rawData.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No scored data found to export.")));
        return;
      }

      final sb = StringBuffer();
      sb.writeln("epoch_start_ms,epoch_end_ms,activity,scaled_activity,conv_activity,mean_hr,sadeh_score,label");

      for (var r in rawData) {
        sb.writeln("${r['epoch_start_ms'] ?? ''},${r['epoch_end_ms'] ?? ''},${r['activity'] ?? 0},${r['scaled_activity'] ?? 0.0},${r['conv_activity'] ?? 0.0},${r['mean_hr'] ?? 0},${r['sadeh_score'] ?? 0.0},${r['label'] ?? 'wake'}");
      }

      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File("${dir.path}/i_sleep_analysis_$ts.csv");
      
      await file.writeAsString(sb.toString());

      if (await file.exists()) {
        await Share.shareXFiles([XFile(file.path)], subject: 'i-Sleep Session Export');
      }
    } catch (e) {
      debugPrint("CSV Export Error: $e");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export failed: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              _buildTopHeader(),
              const SizedBox(height: 20),
              _buildLiveMonitorCard(),
              const SizedBox(height: 30),
              const Text("Bluetooth Pairing", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              _buildDeviceList(devices),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(_status, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        GestureDetector(
          onTap: () => _exportCsv(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12), 
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
            ),
            child: const Text("Export Session", style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveMonitorCard() {
    String currentDuration = "0m";
    if (_isRecording && _sessionStartTime != null) {
      final diff = DateTime.now().millisecondsSinceEpoch - _sessionStartTime!;
      final mins = (diff / 1000 / 60).toInt();
      currentDuration = mins > 60 ? "${(mins / 60).toStringAsFixed(1)}h" : "${mins}m";
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(32)),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("conf: $_conf", style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Row(children: [
                const Icon(Icons.timer_sharp, color: Colors.cyanAccent, size: 16),
                const SizedBox(width: 4),
                Text(currentDuration, style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
              ]),
            ],
          ),
          const SizedBox(height: 15),
          Text(_bpmMean, style: const TextStyle(color: Colors.white, fontSize: 80, fontWeight: FontWeight.bold)),
          const Text("Live Heart Rate", style: TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 25),
          Row(children: [
            Expanded(child: _buildWaveBox("HR Wave", _hrHistory, Colors.cyanAccent, 160)),
            const SizedBox(width: 15),
            Expanded(child: _buildWaveBox("Motion", _motionHistory, Colors.orangeAccent, 4)),
          ]),
          const SizedBox(height: 20),
          _buildXYZRow(),
          const SizedBox(height: 20),
          _buildRecentSyncSection(),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: () async {
              if (_isRecording) {
                _saveSessionToJournal();
              } else {
                if (_connectedDeviceId == null) {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connect device first!")));
                   return;
                }
                setState(() {
                  _isRecording = true; 
                  _hrHistory.clear(); _motionHistory.clear();
                  _lineBuffer.clear(); 
                });
                WakelockPlus.enable(); 
                await _startForegroundService(); 
                final startTs = DateTime.now().millisecondsSinceEpoch;
                _currentSessionId = await AppDb.startSession(startTimeMs: startTs);
                setState(() { _sessionStartTime = startTs; });
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRecording ? Colors.redAccent : const Color(0xFF6ED000),
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            child: Text(_isRecording ? "Stop Recording" : "Start Recording", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildXYZRow() {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_xyzItem("X", _xAxis), _xyzItem("Y", _yAxis), _xyzItem("Z", _zAxis)]);
  }

  Widget _xyzItem(String label, double val) {
    return Column(children: [
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      Text(val.toStringAsFixed(2), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
    ]);
  }

  Widget _buildRecentSyncSection() {
    if (_latestSync == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.sync, color: Colors.cyanAccent, size: 16),
        const SizedBox(width: 10),
        Expanded(child: Text("${_latestSync!['label']} • ${_latestSync!['time']}", style: const TextStyle(color: Colors.white38, fontSize: 11))),
        Text(_latestSync!['val'], style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildWaveBox(String label, List<double> data, Color color, double scale) {
    return Column(children: [
      Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Container(
        height: 40,
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        child: CustomPaint(size: Size.infinite, painter: WaveformPainter(data, color, scale)),
      )
    ]);
  }

  Widget _buildDeviceList(List<DiscoveredDevice> devices) {
    if (devices.isEmpty && _connectedDeviceId == null) {
      return const Padding(
        padding: EdgeInsets.all(20.0),
        child: Center(child: Text("Searching for M5 device...", style: TextStyle(color: Colors.white24))),
      );
    }
    return Column(
      children: devices.map((d) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.bluetooth, color: _connectedDeviceId == d.id ? Colors.greenAccent : Colors.cyanAccent),
        title: Text(d.name.isEmpty ? "Unknown Device" : d.name, style: const TextStyle(color: Colors.white)),
        subtitle: Text(d.id, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        onTap: () => _connect(d.id),
      )).toList(),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> data; final Color color; final double maxScale;
  WaveformPainter(this.data, this.color, this.maxScale);
  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final path = Path();
    final dx = size.width / 49;
    for (int i = 0; i < data.length; i++) {
      double y = size.height - ((data[i] / maxScale) * size.height).clamp(0, size.height);
      if (i == 0) path.moveTo(0, y); else path.lineTo(i * dx, y);
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(CustomPainter old) => true;
}