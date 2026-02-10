import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class AppDb {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'sleep_logger.db');

    // ignore: avoid_print
    print("DB PATH: $path");

    return openDatabase(
      path,
      version: 3, // ✅ bump version so upgrade runs
      onCreate: (Database database, int version) async {
        // ✅ Create samples table (new format)
        await database.execute('''
          CREATE TABLE samples(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp_ms INTEGER NOT NULL,
            hr_bpm INTEGER NOT NULL,
            acc_x REAL NOT NULL,
            acc_y REAL NOT NULL,
            acc_z REAL NOT NULL,
            raw TEXT
          )
        ''');

        // (Optional) If you want to still create epochs for legacy, you can,
        // but not needed anymore. Keeping create minimal.
      },
      onUpgrade: (db, oldV, newV) async {
        // ✅ Create samples table if upgrading from older versions
        if (oldV < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS samples(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp_ms INTEGER NOT NULL,
              hr_bpm INTEGER NOT NULL,
              acc_x REAL NOT NULL,
              acc_y REAL NOT NULL,
              acc_z REAL NOT NULL,
              raw TEXT
            )
          ''');
        }
      },
    );
  }

  // ✅ NEW: insert 5-column sample
  static Future<int> insertSample({
    required int timestampMs,
    required int hrBpm,
    required double accX,
    required double accY,
    required double accZ,
    required String raw,
  }) async {
    final database = await db;
    return database.insert('samples', {
      'timestamp_ms': timestampMs,
      'hr_bpm': hrBpm,
      'acc_x': accX,
      'acc_y': accY,
      'acc_z': accZ,
      'raw': raw,
    });
  }

  // ✅ NEW: count samples
  static Future<int> countSamples() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) AS c FROM samples');
    return (res.first['c'] as int?) ?? 0;
  }

  // ✅ UPDATED: clear samples (not epochs)
  static Future<void> clearAll() async {
    final database = await db;
    await database.delete('samples');
  }

  // ✅ NEW: get all samples
  static Future<List<Map<String, Object?>>> getAllSamples() async {
    final database = await db;
    return database.query('samples', orderBy: 'id ASC');
  }
}