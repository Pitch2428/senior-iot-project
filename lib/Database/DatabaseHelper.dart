// สำหรับ user login
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('isleep_v2.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE UserProfile (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        gender TEXT,
        age INTEGER,
        weight INTEGER,
        m5_id TEXT 
      )
    ''');

    await db.execute('''
      CREATE TABLE syncs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        day TEXT,
        date TEXT,
        time TEXT,
        duration TEXT,
        avg_x REAL,
        avg_y REAL,
        avg_z REAL,
        FOREIGN KEY (user_id) REFERENCES UserProfile (id)
      )
    ''');
  }

  Future<int> insertSync(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('syncs', row);
  }

  Future<List<Map<String, dynamic>>> queryAllSyncs() async {
    Database db = await instance.database;
    return await db.query('syncs', orderBy: 'date DESC, time DESC');
  }

  Future<int> deleteSync(int id) async {
    final db = await instance.database;
    return await db.delete('syncs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAllSyncs() async {
    final db = await instance.database;
    await db.delete('syncs'); // Deletes all rows in the syncs table
  }
  
  Future<List<Map<String, dynamic>>> getSyncsByUser(int userId) async {
  final db = await instance.database;
  return await db.query(
    'syncs',
    where: 'user_id = ?',
    whereArgs: [userId],
    orderBy: 'date DESC',
  );
}

  Future<List<Map<String, dynamic>>> getUserAverages() async {
  final db = await instance.database;
  return await db.rawQuery('''
    SELECT 
      users.name, 
      AVG(syncs.avg_x) as avg_heart_rate, 
      AVG(syncs.avg_z) as avg_motion,
      COUNT(syncs.id) as session_count
    FROM users
    LEFT JOIN syncs ON users.id = syncs.user_id
    GROUP BY users.id
  ''');
 }

  Future<int> insertUser(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('UserProfile', row);
  }

  Future<List<Map<String, dynamic>>> getUsers() async {
    final db = await instance.database;
    return await db.query('UserProfile');
    
  }
}
