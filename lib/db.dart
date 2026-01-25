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

    // ✅ Debug: confirms the real DB location
    // ignore: avoid_print
    print("DB PATH: $path");

    return openDatabase(
      path,
      version: 2,
      onCreate: (Database database, int version) async {
        await database.execute('''
          CREATE TABLE epochs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            conf INTEGER,
            mean_hr REAL,
            rmssd REAL,
            activity_count INTEGER,
            ax_mean REAL,
            ay_mean REAL,
            az_mean REAL,
            ax_std REAL,
            ay_std REAL,
            az_std REAL,
            mag_mean REAL,
            mag_std REAL,
            raw TEXT
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          Future<void> add(String col, String type) async {
            await db.execute('ALTER TABLE epochs ADD COLUMN $col $type');
          }

          await add('ax_mean', 'REAL');
          await add('ay_mean', 'REAL');
          await add('az_mean', 'REAL');
          await add('ax_std', 'REAL');
          await add('ay_std', 'REAL');
          await add('az_std', 'REAL');
          await add('mag_mean', 'REAL');
          await add('mag_std', 'REAL');
        }
      },
    );
  }

  static Future<int> insertEpoch({
    required int ts,
    int? conf,
    double? meanHr,
    double? rmssd,
    int? activityCount,
    double? axMean,
    double? ayMean,
    double? azMean,
    double? axStd,
    double? ayStd,
    double? azStd,
    double? magMean,
    double? magStd,
    required String raw,
  }) async {
    final database = await db;
    return database.insert('epochs', {
      'ts': ts,
      'conf': conf,
      'mean_hr': meanHr,
      'rmssd': rmssd,
      'activity_count': activityCount,
      'ax_mean': axMean,
      'ay_mean': ayMean,
      'az_mean': azMean,
      'ax_std': axStd,
      'ay_std': ayStd,
      'az_std': azStd,
      'mag_mean': magMean,
      'mag_std': magStd,
      'raw': raw,
    });
  }

  static Future<int> countEpochs() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) AS c FROM epochs');
    return (res.first['c'] as int?) ?? 0;
  }

  static Future<void> clearAll() async {
    final database = await db;
    await database.delete('epochs');
  }

  static Future<List<Map<String, Object?>>> getAllEpochs() async {
    final database = await db;
    return database.query('epochs', orderBy: 'id ASC');
  }
}
