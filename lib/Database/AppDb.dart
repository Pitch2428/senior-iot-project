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
      version: 13, // CHANGED: Incremented to version 13
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onOpen: (db) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 10) {
          await _createTables(db);

          if (oldVersion < 6) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS scored_epochs_new(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER,
                epoch_start_ms INTEGER NOT NULL,
                epoch_end_ms INTEGER NOT NULL,
                activity REAL NOT NULL,
                scaled_activity REAL NOT NULL,
                conv_activity REAL NOT NULL,
                mean_hr REAL NOT NULL,
                sadeh_score REAL,
                label TEXT NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id)
              )
            ''');

            await db.execute('''
              INSERT INTO scored_epochs_new(
                id, session_id, epoch_start_ms, epoch_end_ms, activity, 
                scaled_activity, conv_activity, mean_hr, sadeh_score, label
              )
              SELECT id, NULL, epoch_start_ms, epoch_end_ms, activity, 
                     activity, conv_activity, mean_hr, NULL, label
              FROM scored_epochs
            ''');

            await db.execute('DROP TABLE IF EXISTS scored_epochs');
            await db.execute('ALTER TABLE scored_epochs_new RENAME TO scored_epochs');
            await db.execute('CREATE INDEX IF NOT EXISTS idx_scored_epochs_session_start ON scored_epochs(session_id, epoch_start_ms)');
          }

          if (oldVersion < 7) {
            final tableInfo = await db.rawQuery("PRAGMA table_info(samples)");
            final hasSessionId = tableInfo.any((row) => row['name'] == 'session_id');
            if (!hasSessionId) {
              await db.execute('ALTER TABLE samples ADD COLUMN session_id INTEGER');
            }
            await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_session_timestamp ON samples(session_id, timestamp_ms)');
          }

          if (oldVersion < 8) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS sleep_summaries(
                summary_id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL UNIQUE,
                time_in_bed_min REAL,
                total_sleep_time_min REAL,
                sleep_latency_min REAL,
                waso_min REAL,
                sleep_efficiency_pct REAL,
                sleep_onset_ms INTEGER,
                final_wake_ms INTEGER,
                generated_at_ms INTEGER NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id)
              )
            ''');
            await db.execute('CREATE INDEX IF NOT EXISTS idx_sleep_summaries_session ON sleep_summaries(session_id)');
          }

          if (oldVersion < 9) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS raw_5s_blocks(
                block_id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                block_start_ms INTEGER NOT NULL,
                block_end_ms INTEGER NOT NULL,
                sample_count INTEGER NOT NULL,
                mean_hr REAL NOT NULL,
                activity_sum REAL NOT NULL,
                activity_mean REAL NOT NULL,
                created_at_ms INTEGER NOT NULL,
                UNIQUE(session_id, block_start_ms),
                FOREIGN KEY(session_id) REFERENCES sessions(session_id)
              )
            ''');
            await db.execute('CREATE INDEX IF NOT EXISTS idx_raw_5s_blocks_session_start ON raw_5s_blocks(session_id, block_start_ms)');
          }

          if (oldVersion < 10) {
            final tableInfo = await db.rawQuery("PRAGMA table_info(scored_epochs)");
            final hasSessionId = tableInfo.any((row) => row['name'] == 'session_id');
            if (!hasSessionId) {
              await db.execute('''
                CREATE TABLE IF NOT EXISTS scored_epochs_v10(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id INTEGER,
                  epoch_start_ms INTEGER NOT NULL,
                  epoch_end_ms INTEGER NOT NULL,
                  activity REAL NOT NULL,
                  scaled_activity REAL NOT NULL,
                  conv_activity REAL NOT NULL,
                  mean_hr REAL NOT NULL,
                  sadeh_score REAL,
                  label TEXT NOT NULL,
                  FOREIGN KEY(session_id) REFERENCES sessions(session_id)
                )
              ''');
              await db.execute('''
                INSERT INTO scored_epochs_v10(
                  id, session_id, epoch_start_ms, epoch_end_ms, activity, 
                  scaled_activity, conv_activity, mean_hr, sadeh_score, label
                )
                SELECT id, NULL, epoch_start_ms, epoch_end_ms, activity, 
                       scaled_activity, conv_activity, mean_hr, sadeh_score, label
                FROM scored_epochs
              ''');
              await db.execute('DROP TABLE IF EXISTS scored_epochs');
              await db.execute('ALTER TABLE scored_epochs_v10 RENAME TO scored_epochs');
            }
            await db.execute('CREATE INDEX IF NOT EXISTS idx_scored_epochs_session_start ON scored_epochs(session_id, epoch_start_ms)');
          }
        }

        if (oldVersion < 11) {
          final tableInfo = await db.rawQuery("PRAGMA table_info(sleep_summaries)");
          final requiredColumns = {
            'sleep_latency_min': 'REAL',
            'waso_min': 'REAL',
            'sleep_efficiency_pct': 'REAL',
            'sleep_onset_ms': 'INTEGER',
            'final_wake_ms': 'INTEGER',
          };

          for (var entry in requiredColumns.entries) {
            final exists = tableInfo.any((row) => row['name'] == entry.key);
            if (!exists) {
              await db.execute('ALTER TABLE sleep_summaries ADD COLUMN ${entry.key} ${entry.value}');
            }
          }
        }

        if (oldVersion < 12) {
          final tableInfo = await db.rawQuery("PRAGMA table_info(sleep_summaries)");
          final hasSleepScore = tableInfo.any((row) => row['name'] == 'sleep_score');
          if (!hasSleepScore) {
            await db.execute('ALTER TABLE sleep_summaries ADD COLUMN sleep_score REAL');
          }
        }

        // NEW: Version 13 - No schema changes, just for retention cleanup
        if (oldVersion < 13) {
          // Clean up old data when upgrading to version 13
          await _cleanupOldData(db);
        }
      },
    );
  }

  // NEW: Clean up old data (keep last 14 days)
  static Future<void> _cleanupOldData(Database db) async {
    final cutoffTime = DateTime.now().subtract(const Duration(days: 14)).millisecondsSinceEpoch;
    
    // Get sessions older than 14 days
    final oldSessions = await db.query(
      'sessions',
      where: 'start_time_ms < ?',
      whereArgs: [cutoffTime],
    );
    
    for (final session in oldSessions) {
      final sessionId = session['session_id'] as int;
      await db.transaction((txn) async {
        await txn.delete('samples', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('raw_5s_blocks', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('sleep_summaries', where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete('sessions', where: 'session_id = ?', whereArgs: [sessionId]);
      });
    }
    
    if (oldSessions.isNotEmpty) {
      print('🧹 Cleaned up ${oldSessions.length} old sessions (>14 days)');
    }
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions(
        session_id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_time_ms INTEGER NOT NULL,
        end_time_ms INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS samples(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER,
        timestamp_ms INTEGER NOT NULL,
        hr_bpm INTEGER NOT NULL,
        acc_x REAL NOT NULL,
        acc_y REAL NOT NULL,
        acc_z REAL NOT NULL,
        raw TEXT,
        FOREIGN KEY(session_id) REFERENCES sessions(session_id)
      )
    ''');

    final samplesInfo = await db.rawQuery("PRAGMA table_info(samples)");
    if (!samplesInfo.any((row) => row['name'] == 'session_id')) {
      await db.execute('ALTER TABLE samples ADD COLUMN session_id INTEGER');
    }

    await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp_ms)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_session_timestamp ON samples(session_id, timestamp_ms)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_5s_blocks(
        block_id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        block_start_ms INTEGER NOT NULL,
        block_end_ms INTEGER NOT NULL,
        sample_count INTEGER NOT NULL,
        mean_hr REAL NOT NULL,
        activity_sum REAL NOT NULL,
        activity_mean REAL NOT NULL,
        created_at_ms INTEGER NOT NULL,
        UNIQUE(session_id, block_start_ms),
        FOREIGN KEY(session_id) REFERENCES sessions(session_id)
      )
    ''');

    await db.execute('CREATE INDEX IF NOT EXISTS idx_raw_5s_blocks_session_start ON raw_5s_blocks(session_id, block_start_ms)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS scored_epochs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER,
        epoch_start_ms INTEGER NOT NULL,
        epoch_end_ms INTEGER NOT NULL,
        activity REAL NOT NULL,
        scaled_activity REAL NOT NULL,
        conv_activity REAL NOT NULL,
        mean_hr REAL NOT NULL,
        sadeh_score REAL,
        label TEXT NOT NULL,
        FOREIGN KEY(session_id) REFERENCES sessions(session_id)
      )
    ''');

    await db.execute('CREATE INDEX IF NOT EXISTS idx_scored_epochs_session_start ON scored_epochs(session_id, epoch_start_ms)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_summaries(
        summary_id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL UNIQUE,
        time_in_bed_min REAL,
        total_sleep_time_min REAL,
        sleep_latency_min REAL,
        waso_min REAL,
        sleep_efficiency_pct REAL,
        sleep_onset_ms INTEGER,
        final_wake_ms INTEGER,
        sleep_score REAL,
        generated_at_ms INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES sessions(session_id)
      )
    ''');

    await db.execute('CREATE INDEX IF NOT EXISTS idx_sleep_summaries_session ON sleep_summaries(session_id)');
  }

  // --- DELETE LOGIC ---

  static Future<void> deleteSession(int sessionId) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('samples', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('raw_5s_blocks', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('sleep_summaries', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('sessions', where: 'session_id = ?', whereArgs: [sessionId]);
    });
  }

  // NEW: Delete sessions older than specified duration
  static Future<int> deleteSessionsOlderThan(Duration duration) async {
    final database = await db;
    final cutoffTime = DateTime.now().subtract(duration).millisecondsSinceEpoch;
    
    final oldSessions = await database.query(
      'sessions',
      where: 'start_time_ms < ?',
      whereArgs: [cutoffTime],
    );
    
    int deletedCount = 0;
    for (final session in oldSessions) {
      final sessionId = session['session_id'] as int;
      await deleteSession(sessionId);
      deletedCount++;
    }
    
    if (deletedCount > 0) {
      print('🧹 Cleaned up $deletedCount old sessions (>${duration.inDays} days)');
    }
    
    return deletedCount;
  }

  // NEW: Clean up old data (public method to call on app start)
  static Future<void> cleanupOldData({int retentionDays = 14}) async {
    await deleteSessionsOlderThan(Duration(days: retentionDays));
  }

  // NEW: Get oldest session age in days
  static Future<int> getOldestSessionDays() async {
    final database = await db;
    final result = await database.rawQuery('''
      SELECT MIN(start_time_ms) as oldest 
      FROM sessions
    ''');
    
    final oldestMs = result.first['oldest'] as int?;
    if (oldestMs == null) return 0;
    
    final oldestDate = DateTime.fromMillisecondsSinceEpoch(oldestMs);
    return DateTime.now().difference(oldestDate).inDays;
  }

  // NEW: Get storage statistics
  static Future<Map<String, int>> getStorageStats() async {
    final database = await db;
    
    final sessionCount = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM sessions')
    ) ?? 0;
    
    final sampleCount = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM samples')
    ) ?? 0;
    
    final epochCount = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM scored_epochs')
    ) ?? 0;
    
    final summaryCount = Sqflite.firstIntValue(
      await database.rawQuery('SELECT COUNT(*) FROM sleep_summaries')
    ) ?? 0;
    
    return {
      'sessions': sessionCount,
      'samples': sampleCount,
      'epochs': epochCount,
      'summaries': summaryCount,
    };
  }

  // --- HELPER METHODS ---

  static Future<int> countSamples() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) FROM samples');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<int> countRaw5sBlocks() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) FROM raw_5s_blocks');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<int> countScoredEpochs() async {
    final database = await db;
    final res = await database.rawQuery('SELECT COUNT(*) FROM scored_epochs');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<int> countScoredEpochsForSession(int sessionId) async {
    final database = await db;
    final res = await database.rawQuery(
      'SELECT COUNT(*) FROM scored_epochs WHERE session_id = ?',
      [sessionId],
    );
    return Sqflite.firstIntValue(res) ?? 0;
  }

  static Future<List<Map<String, Object?>>> getAllSamples() async {
    final database = await db;
    return database.query('samples', orderBy: 'timestamp_ms ASC');
  }

  static Future<List<Map<String, Object?>>> getAllScoredEpochs() async {
    final database = await db;
    return database.query('scored_epochs', orderBy: 'session_id ASC, epoch_start_ms ASC');
  }

  static Future<List<Map<String, Object?>>> getAllRaw5sBlocks() async {
    final database = await db;
    return database.query('raw_5s_blocks', orderBy: 'block_start_ms ASC');
  }

  // --- CRUD Logic ---

  static Future<int> startSession({required int startTimeMs}) async {
    final database = await db;
    return await database.insert('sessions', {
      'start_time_ms': startTimeMs,
      'end_time_ms': null,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  static Future<void> endSession({required int sessionId, required int endTimeMs}) async {
    final database = await db;
    await database.update('sessions', {'end_time_ms': endTimeMs},
      where: 'session_id = ?', whereArgs: [sessionId]);
  }

  static Future<int> insertSample({
    required int sessionId, required int timestampMs, required int hrBpm,
    required double accX, required double accY, required double accZ, required String raw,
  }) async {
    final database = await db;
    return database.insert('samples', {
      'session_id': sessionId, 'timestamp_ms': timestampMs, 'hr_bpm': hrBpm,
      'acc_x': accX, 'acc_y': accY, 'acc_z': accZ, 'raw': raw,
    });
  }

  static Future<int> insertRaw5sBlock({
    required int sessionId, required int blockStartMs, required int blockEndMs,
    required int sampleCount, required double meanHr, required double activitySum, required double activityMean,
  }) async {
    final database = await db;
    return database.insert('raw_5s_blocks', {
      'session_id': sessionId, 'block_start_ms': blockStartMs, 'block_end_ms': blockEndMs,
      'sample_count': sampleCount, 'mean_hr': meanHr, 'activity_sum': activitySum,
      'activity_mean': activityMean, 'created_at_ms': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> replaceScoredEpochs({required int sessionId, required List<Map<String, Object?>> rows}) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId]);
      for (final row in rows) {
        await txn.insert('scored_epochs', {'session_id': sessionId, ...row}, 
        conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<void> upsertSleepSummary({
    required int sessionId, 
    required double timeInBedMin, 
    required double totalSleepTimeMin,
    required double sleepLatencyMin, 
    required double wasoMin, 
    required double sleepEfficiencyPct,
    required int? sleepOnsetMs, 
    required int? finalWakeMs,
    required double sleepScore,
  }) async {
    final database = await db;
    await database.insert('sleep_summaries', {
      'session_id': sessionId, 
      'time_in_bed_min': timeInBedMin, 
      'total_sleep_time_min': totalSleepTimeMin,
      'sleep_latency_min': sleepLatencyMin, 
      'waso_min': wasoMin, 
      'sleep_efficiency_pct': sleepEfficiencyPct,
      'sleep_onset_ms': sleepOnsetMs, 
      'final_wake_ms': finalWakeMs,
      'sleep_score': sleepScore,
      'generated_at_ms': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --- QUERY METHODS ---

  static Future<Map<String, Object?>?> getSleepSummaryForSession(int sessionId) async {
    final database = await db;
    final rows = await database.query('sleep_summaries', where: 'session_id = ?', whereArgs: [sessionId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, Object?>>> getAllSleepSummaries() async {
    final database = await db;
    return database.query('sleep_summaries', orderBy: 'generated_at_ms DESC');
  }

  static Future<List<Map<String, Object?>>> getSamplesForSession(int sessionId) async {
    final database = await db;
    return database.query('samples', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'timestamp_ms ASC');
  }

  static Future<List<Map<String, Object?>>> get5sBlocksForSession(int sessionId) async {
    final dbClient = await db;
    return await dbClient.query(
      'raw_5s_blocks',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'block_start_ms ASC',
    );
  }

  static Future<List<Map<String, Object?>>> getScoredEpochsForSession(int sessionId) async {
    final database = await db;
    return database.query('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'epoch_start_ms ASC');
  }

  static Future<void> clearAll() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('samples');
      await txn.delete('raw_5s_blocks');
      await txn.delete('scored_epochs');
      await txn.delete('sleep_summaries');
      await txn.delete('sessions');

      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'samples'");
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'raw_5s_blocks'");
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'scored_epochs'");
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'sleep_summaries'");
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'sessions'");
    });
  }

  static Future<void> clearScoredEpochs() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('scored_epochs');
      await txn.execute("DELETE FROM sqlite_sequence WHERE name = 'scored_epochs'");
    });
  }

  static Future<void> clearScoredEpochsForSession(int sessionId) async {
    final database = await db;
    await database.delete('scored_epochs', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}