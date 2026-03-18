import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

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

    print('DB PATH: $path');

    return openDatabase(
      path,
      version: 6,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 6) {
          await _createTables(db);

          if (oldVersion < 6) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS scored_epochs_new(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                epoch_start_ms INTEGER NOT NULL,
                epoch_end_ms INTEGER NOT NULL,
                activity REAL NOT NULL,
                scaled_activity REAL NOT NULL,
                conv_activity REAL NOT NULL,
                mean_hr REAL NOT NULL,
                sadeh_score REAL,
                label TEXT NOT NULL
              )
            ''');

            await db.execute('''
              INSERT INTO scored_epochs_new(
                id,
                epoch_start_ms,
                epoch_end_ms,
                activity,
                scaled_activity,
                conv_activity,
                mean_hr,
                sadeh_score,
                label
              )
              SELECT
                id,
                epoch_start_ms,
                epoch_end_ms,
                activity,
                activity,
                conv_activity,
                mean_hr,
                NULL,
                label
              FROM scored_epochs
            ''');

            await db.execute('DROP TABLE IF EXISTS scored_epochs');
            await db.execute(
              'ALTER TABLE scored_epochs_new RENAME TO scored_epochs',
            );

            await db.execute('''
              CREATE INDEX IF NOT EXISTS idx_scored_epochs_start
              ON scored_epochs(epoch_start_ms)
            ''');
          }
        }
      },
    );
  }

  static Future<void> _createTables(Database db) async {
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

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_samples_timestamp
      ON samples(timestamp_ms)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS scored_epochs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        epoch_start_ms INTEGER NOT NULL,
        epoch_end_ms INTEGER NOT NULL,
        activity REAL NOT NULL,
        scaled_activity REAL NOT NULL,
        conv_activity REAL NOT NULL,
        mean_hr REAL NOT NULL,
        sadeh_score REAL,
        label TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_scored_epochs_start
      ON scored_epochs(epoch_start_ms)
    ''');
  }

  static Future<int> insertSample({
    required int timestampMs,
    required int hrBpm,
    required double accX,
    required double accY,
    required double accZ,
    required String raw,
  }) async {
    final database = await db;

    return database.insert(
      'samples',
      {
        'timestamp_ms': timestampMs,
        'hr_bpm': hrBpm,
        'acc_x': accX,
        'acc_y': accY,
        'acc_z': accZ,
        'raw': raw,
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  static Future<void> replaceScoredEpochs(
      List<Map<String, Object?>> rows,
      ) async {
    final database = await db;

    await database.transaction((txn) async {
      await txn.delete('scored_epochs');

      for (final row in rows) {
        await txn.insert(
          'scored_epochs',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  static Future<int> countSamples() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) FROM samples');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<int> countScoredEpochs() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) FROM scored_epochs');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<void> clearAll() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('samples');
      await txn.delete('scored_epochs');
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'samples'");
      await txn.execute(
        "DELETE FROM sqlite_sequence WHERE name = 'scored_epochs'",
      );
    });
  }

  static Future<void> clearScoredEpochs() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('scored_epochs');
      await txn.execute(
        "DELETE FROM sqlite_sequence WHERE name = 'scored_epochs'",
      );
    });
  }

  static Future<List<Map<String, Object?>>> getAllSamples() async {
    final database = await db;
    return database.query(
      'samples',
      orderBy: 'timestamp_ms ASC',
    );
  }

  static Future<List<Map<String, Object?>>> getAllScoredEpochs() async {
    final database = await db;
    return database.query(
      'scored_epochs',
      orderBy: 'epoch_start_ms ASC',
    );
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}