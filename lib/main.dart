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

  // queue DB writes to prevent "database is locked"
  Future<void> _dbQueue = Future.value();

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

  // ---------- BLE permissions ----------
  Future<bool> _ensureBlePermissions() async {
    final loc = await Permission.locationWhenInUse.request();
    if (!loc.isGranted) {
      if (mounted) {
        setState(() => _status = "Location permission denied (BLE scan needs it)");
      }
      return false;
    }
    return true;
  }

  // ---------- BLE ----------
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
        .listen((d) {
      _found[d.id] = d;
      if (mounted) setState(() {});
    }, onError: (e) {
      if (mounted) setState(() => _status = "Scan error: $e");
    });
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
        .listen((update) async {
      if (!mounted) return;
      setState(() => _status = "Connection: ${update.connectionState}");

      if (update.connectionState == DeviceConnectionState.connected) {
        _connectedId = deviceId;
        await _subscribe(deviceId);
      }

      if (update.connectionState == DeviceConnectionState.disconnected) {
        _connectedId = null;
        await _notifySub?.cancel();
        _notifySub = null;
        _flushTimer?.cancel();
        if (mounted) setState(() => _status = "Disconnected");
      }
    }, onError: (e) {
      if (mounted) setState(() => _status = "Connect error: $e");
    });
  }

  Future<void> _subscribe(String deviceId) async {
    final c = QualifiedCharacteristic(
      deviceId: deviceId,
      serviceId: Uuid.parse(nusServiceUuid),
      characteristicId: Uuid.parse(nusTxUuid),
    );

    await _notifySub?.cancel();
    _notifySub = _ble.subscribeToCharacteristic(c).listen((data) {
      _handleIncoming(Uint8List.fromList(data));
    }, onError: (e) {
      if (mounted) setState(() => _status = "Notify error: $e");
    });

    if (mounted) setState(() => _status = "Subscribed ✅ (waiting for data)");
  }

  // ---------- Parse (timestamp_ms,hr_bpm,acc_x,acc_y,acc_z) ----------
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

    if (t == null || hr == null || ax == null || ay == null || az == null) return null;

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
    if (mounted) setState(() => _dbRows = c);
  }

  Future<void> _commitLine(String line) async {
    final cleaned = line.trim();
    if (cleaned.isEmpty) return;

    // show latest
    if (mounted) {
      setState(() {
        _lines.insert(0, cleaned);
        if (_lines.length > 200) _lines.removeLast();
      });
    }

    final parsed = _parseSample5(cleaned);
    if (parsed == null) {
      // ignore non-data lines like CONNECTED
      return;
    }

    try {
      await AppDb.insertSample(
        timestampMs: parsed["timestamp_ms"] as int,
        hrBpm: parsed["hr_bpm"] as int,
        accX: parsed["acc_x"] as double,
        accY: parsed["acc_y"] as double,
        accZ: parsed["acc_z"] as double,
        raw: cleaned,
      );

      await _refreshDbRows();
    } catch (e) {
      if (mounted) {
        setState(() => _status = "DB insert error: $e");
      }
    }
  }

  // ---------- Incoming BLE bytes ----------
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

  // ---------- Clear DB ----------
  Future<void> _clearDatabase() async {
    await AppDb.clearAll();
    await _refreshDbRows();
    if (!mounted) return;
    setState(() {
      _lines.clear();
      _status = "Database cleared ✅";
    });
  }

  // ---------- CSV Export (Share) ----------
  String _buildCsv(List<Map<String, Object?>> rows) {
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

  Future<void> _exportCsvToPhone() async {
    try {
      setState(() => _status = "Preparing CSV export...");

      final rows = await AppDb.getAllSamples();
      if (rows.isEmpty) {
        setState(() => _status = "No data to export");
        return;
      }

      final csv = _buildCsv(rows);
      final fileName = "sleep_raw_${DateTime.now().millisecondsSinceEpoch}.csv";

      final ext = await getExternalStorageDirectory();
      if (ext == null) {
        setState(() => _status = "Export failed: external storage not available");
        return;
      }

      final file = File("${ext.path}/$fileName");
      await file.writeAsString(csv, flush: true);

      await Share.shareXFiles([XFile(file.path)], text: "Sleep raw CSV");
      setState(() => _status = "Saved ✅ and shared:\n${file.path}");
    } catch (e) {
      setState(() => _status = "Export failed: $e");
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));

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
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(onPressed: _startScan, child: const Text("Scan")),
                ElevatedButton(onPressed: _stopScan, child: const Text("Stop")),
                ElevatedButton(onPressed: _clearDatabase, child: const Text("Clear DB")),
                ElevatedButton(onPressed: _exportCsvToPhone, child: const Text("Export CSV to Phone")),
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
                    trailing: _connectedId == d.id ? const Icon(Icons.check, color: Colors.green) : null,
                    onTap: () => _connect(d.id),
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