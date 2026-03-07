import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'sadeh.dart';

const nusServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const nusTxUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleep BLE Logger',
      theme: ThemeData(useMaterial3: true),
      home: const BleHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BleHome extends StatefulWidget {
  const BleHome({super.key});

  @override
  State<BleHome> createState() => _BleHomeState();
}

class _BleHomeState extends State<BleHome> {
  final _ble = FlutterReactiveBle();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  final Map<String, DiscoveredDevice> _found = {};
  final List<String> _lines = [];
  final _lineBuffer = StringBuffer();

  String _status = "Idle";
  String? _connectedId;

  int _bytesIn = 0;
  int _dbRows = 0;

  Timer? _flushTimer;
  Future<void> _dbQueue = Future.value();

  List<ScoredEpoch> _scoredEpochs = [];

  @override
  void initState() {
    super.initState();
    _refreshDbRows();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _flushTimer?.cancel();
    super.dispose();
  }

  Future<bool> _ensureBlePermissions() async {
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      final loc = await Permission.locationWhenInUse.request();

      final ok = scan.isGranted && connect.isGranted && loc.isGranted;

      if (!ok && mounted) {
        setState(() => _status = "BLE permissions denied");
      }
      return ok;
    }

    return true;
  }

  Future<void> _startScan() async {
    final ok = await _ensureBlePermissions();
    if (!ok) return;

    setState(() {
      _status = "Scanning...";
      _found.clear();
    });

    await _scanSub?.cancel();
    _scanSub = _ble
        .scanForDevices(
      withServices: [Uuid.parse(nusServiceUuid)],
      scanMode: ScanMode.lowLatency,
    )
        .listen(
          (d) {
        _found[d.id] = d;
        if (mounted) setState(() {});
      },
      onError: (e) {
        if (mounted) setState(() => _status = "Scan error: $e");
      },
    );
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    if (mounted) setState(() => _status = "Scan stopped");
  }

  Future<void> _connect(String deviceId) async {
    await _stopScan();

    if (!mounted) return;
    setState(() {
      _status = "Connecting...";
      _connectedId = null;
      _bytesIn = 0;
      _lines.clear();
      _lineBuffer.clear();
    });

    _flushTimer?.cancel();
    await _connSub?.cancel();

    _connSub = _ble
        .connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 12),
    )
        .listen(
          (update) async {
        if (!mounted) return;

        setState(() => _status = "Connection: ${update.connectionState}");

        if (update.connectionState == DeviceConnectionState.connected) {
          _connectedId = deviceId;
          await _subscribe(deviceId);
        }

        if (update.connectionState == DeviceConnectionState.disconnected) {
          await _flushPendingBufferNow();
          _connectedId = null;
          await _notifySub?.cancel();
          _notifySub = null;
          _flushTimer?.cancel();
          if (mounted) setState(() => _status = "Disconnected");
        }
      },
      onError: (e) {
        if (mounted) setState(() => _status = "Connect error: $e");
      },
    );
  }

  Future<void> _subscribe(String deviceId) async {
    final c = QualifiedCharacteristic(
      deviceId: deviceId,
      serviceId: Uuid.parse(nusServiceUuid),
      characteristicId: Uuid.parse(nusTxUuid),
    );

    await _notifySub?.cancel();
    _notifySub = _ble.subscribeToCharacteristic(c).listen(
          (data) {
        _handleIncoming(Uint8List.fromList(data));
      },
      onError: (e) {
        if (mounted) setState(() => _status = "Notify error: $e");
      },
    );

    if (mounted) {
      setState(() => _status = "Subscribed ✅ (waiting for data)");
    }
  }

  Map<String, dynamic>? _parseSample5(String line) {
    final parts = line.trim().split(',');
    if (parts.length != 5) return null;

    int? toInt(String s) => int.tryParse(s.trim());
    double? toDouble(String s) => double.tryParse(s.trim());

    final t = toInt(parts[0]);
    final hr = toInt(parts[1]);
    final ax = toDouble(parts[2]);
    final ay = toDouble(parts[3]);
    final az = toDouble(parts[4]);

    if (t == null || hr == null || ax == null || ay == null || az == null) {
      return null;
    }

    return {
      "timestamp_ms": t,
      "hr_bpm": hr,
      "acc_x": ax,
      "acc_y": ay,
      "acc_z": az,
    };
  }

  Future<void> _refreshDbRows() async {
    final c = await AppDb.countSamples();
    if (mounted) {
      setState(() => _dbRows = c);
    }
  }

  Future<void> _commitLine(String line) async {
    final cleaned = line.trim();
    if (cleaned.isEmpty) return;

    if (mounted) {
      setState(() {
        _lines.insert(0, cleaned);
        if (_lines.length > 200) _lines.removeLast();
      });
    }

    final parsed = _parseSample5(cleaned);
    if (parsed == null) return;

    try {
      await AppDb.insertSample(
        timestampMs: parsed["timestamp_ms"] as int,
        hrBpm: parsed["hr_bpm"] as int,
        accX: parsed["acc_x"] as double,
        accY: parsed["acc_y"] as double,
        accZ: parsed["acc_z"] as double,
        raw: cleaned,
      );

      if (mounted) {
        setState(() => _dbRows++);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = "DB insert error: $e");
      }
    }
  }

  void _handleIncoming(Uint8List bytes) {
    _bytesIn += bytes.length;

    final chunk = utf8.decode(bytes, allowMalformed: true);
    _lineBuffer.write(chunk);

    final full = _lineBuffer.toString();
    final parts = full.split(RegExp(r'\r?\n'));

    _lineBuffer
      ..clear()
      ..write(parts.last);

    for (int i = 0; i < parts.length - 1; i++) {
      final l = parts[i].trim();
      if (l.isEmpty) continue;
      _dbQueue = _dbQueue.then((_) => _commitLine(l));
    }

    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 1500), () {
      final pending = _lineBuffer.toString().trim();
      if (pending.isNotEmpty) {
        _dbQueue = _dbQueue.then((_) => _commitLine(pending));
        _lineBuffer.clear();
      }
    });

    if (mounted) setState(() {});
  }

  Future<void> _flushPendingBufferNow() async {
    _flushTimer?.cancel();

    final pending = _lineBuffer.toString().trim();
    if (pending.isNotEmpty) {
      _lineBuffer.clear();
      _dbQueue = _dbQueue.then((_) => _commitLine(pending));
    }

    await _dbQueue;
  }

  Future<void> _clearDatabase() async {
    await _flushPendingBufferNow();
    await AppDb.clearAll();

    if (!mounted) return;
    setState(() {
      _lines.clear();
      _scoredEpochs.clear();
      _dbRows = 0;
      _status = "Database cleared ✅";
    });
  }

  String _buildRawCsv(List<Map<String, Object?>> rows) {
    final sb = StringBuffer();
    sb.writeln("timestamp_ms,hr_bpm,acc_x,acc_y,acc_z");

    for (final r in rows) {
      sb.writeln([
        r['timestamp_ms'] ?? '',
        r['hr_bpm'] ?? '',
        r['acc_x'] ?? '',
        r['acc_y'] ?? '',
        r['acc_z'] ?? '',
      ].join(','));
    }

    return sb.toString();
  }

  Future<void> _exportRawCsvToPhone() async {
    try {
      setState(() => _status = "Preparing raw CSV export...");

      await _flushPendingBufferNow();
      final rows = await AppDb.getAllSamples();

      if (rows.isEmpty) {
        setState(() => _status = "No raw data to export");
        return;
      }

      final csv = _buildRawCsv(rows);
      final fileName = "sleep_raw_${DateTime.now().millisecondsSinceEpoch}.csv";

      final ext = await getExternalStorageDirectory();
      if (ext == null) {
        setState(() => _status = "Export failed: external storage not available");
        return;
      }

      final file = File("${ext.path}/$fileName");
      await file.writeAsString(csv, flush: true);

      await Share.shareXFiles([XFile(file.path)], text: "Sleep raw CSV");

      if (mounted) {
        setState(() => _status = "Raw CSV saved ✅\n${file.path}");
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = "Raw export failed: $e");
      }
    }
  }

  Future<void> _runSleepScoring() async {
    try {
      if (mounted) {
        setState(() => _status = "Scoring sleep/wake...");
      }

      await _flushPendingBufferNow();
      final rows = await AppDb.getAllSamples();

      if (rows.isEmpty) {
        if (mounted) setState(() => _status = "No samples available");
        return;
      }

      final epochs = SleepScorer.scoreRows(rows, epochSeconds: 60);

      if (!mounted) return;
      setState(() {
        _scoredEpochs = epochs;
        _status = "Sleep scoring done ✅  Epochs: ${epochs.length}";
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = "Sleep scoring failed: $e");
      }
    }
  }

  String _buildScoredCsv(List<ScoredEpoch> epochs) {
    final sb = StringBuffer();
    sb.writeln("epoch_start_ms,epoch_end_ms,activity,mean_hr,label");

    for (final e in epochs) {
      sb.writeln([
        e.startMs,
        e.endMs,
        e.activity.toStringAsFixed(6),
        e.meanHr.toStringAsFixed(2),
        e.isSleep ? "sleep" : "wake",
      ].join(','));
    }

    return sb.toString();
  }

  Future<void> _exportScoredCsvToPhone() async {
    try {
      await _flushPendingBufferNow();

      if (_scoredEpochs.isEmpty) {
        await _runSleepScoring();
      }

      if (_scoredEpochs.isEmpty) {
        if (mounted) setState(() => _status = "No scored epochs to export");
        return;
      }

      if (mounted) {
        setState(() => _status = "Preparing scored CSV export...");
      }

      final csv = _buildScoredCsv(_scoredEpochs);
      final fileName =
          "sleep_scored_${DateTime.now().millisecondsSinceEpoch}.csv";

      final ext = await getExternalStorageDirectory();
      if (ext == null) {
        if (mounted) {
          setState(() => _status = "Export failed: external storage not available");
        }
        return;
      }

      final file = File("${ext.path}/$fileName");
      await file.writeAsString(csv, flush: true);

      await Share.shareXFiles([XFile(file.path)], text: "Sleep scored CSV");

      if (mounted) {
        setState(() => _status = "Scored CSV saved ✅\n${file.path}");
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = "Scored export failed: $e");
      }
    }
  }

  int get _sleepCount => _scoredEpochs.where((e) => e.isSleep).length;
  int get _wakeCount => _scoredEpochs.where((e) => !e.isSleep).length;

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(title: const Text("Sleep BLE Logger")),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status),
            const SizedBox(height: 6),
            Text("Bytes in: $_bytesIn"),
            Text("DB rows: $_dbRows"),
            Text(
              "Scored epochs: ${_scoredEpochs.length}   Sleep: $_sleepCount   Wake: $_wakeCount",
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _startScan,
                  child: const Text("Scan"),
                ),
                ElevatedButton(
                  onPressed: _stopScan,
                  child: const Text("Stop"),
                ),
                ElevatedButton(
                  onPressed: _clearDatabase,
                  child: const Text("Clear DB"),
                ),
                ElevatedButton(
                  onPressed: _exportRawCsvToPhone,
                  child: const Text("Export Raw CSV"),
                ),
                ElevatedButton(
                  onPressed: _runSleepScoring,
                  child: const Text("Score Sleep/Wake"),
                ),
                ElevatedButton(
                  onPressed: _exportScoredCsvToPhone,
                  child: const Text("Export Scored CSV"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text("Found devices (tap to connect):"),
            SizedBox(
              height: 150,
              child: ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, i) {
                  final d = devices[i];
                  final name = d.name.isNotEmpty ? d.name : "(no name)";
                  return ListTile(
                    dense: true,
                    title: Text(name),
                    subtitle: Text("id: ${d.id}   rssi: ${d.rssi}"),
                    trailing: _connectedId == d.id
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                    onTap: () => _connect(d.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            const Text("Latest scored epochs:"),
            SizedBox(
              height: 140,
              child: _scoredEpochs.isEmpty
                  ? const Center(child: Text("No scored epochs yet"))
                  : ListView.builder(
                itemCount:
                _scoredEpochs.length > 20 ? 20 : _scoredEpochs.length,
                itemBuilder: (_, i) {
                  final e = _scoredEpochs[i];
                  return Text(
                    "${e.startMs}  "
                        "act=${e.activity.toStringAsFixed(3)}  "
                        "hr=${e.meanHr.toStringAsFixed(1)}  "
                        "${e.isSleep ? 'SLEEP' : 'WAKE'}",
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            const Text("Incoming data:"),
            Expanded(
              child: ListView.builder(
                itemCount: _lines.length,
                itemBuilder: (_, i) => Text(_lines[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}