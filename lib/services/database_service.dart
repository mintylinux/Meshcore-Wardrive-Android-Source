import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import 'dart:io';

class DatabaseService {
  static Database? _database;
  static const String _databaseName = 'meshcore_wardrive.db';
  static const int _databaseVersion = 3;

  static const String tableSamples = 'samples';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String path = join(appDocDir.path, _databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableSamples (
        id TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        timestamp INTEGER NOT NULL,
        path TEXT,
        geohash TEXT NOT NULL,
        rssi INTEGER,
        snr INTEGER,
        pingSuccess INTEGER,
        observerNames TEXT
      )
    ''');

    // Create index on geohash for faster queries
    await db.execute('''
      CREATE INDEX idx_samples_geohash ON $tableSamples (geohash)
    ''');

    // Create index on timestamp for sorting
    await db.execute('''
      CREATE INDEX idx_samples_timestamp ON $tableSamples (timestamp)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add new columns for ping data
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN rssi INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN snr INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN pingSuccess INTEGER');
    }
    if (oldVersion < 3) {
      // Add observer names column
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN observerNames TEXT');
    }
  }

  /// Insert a sample into the database
  Future<void> insertSample(Sample sample) async {
    final db = await database;
    await db.insert(
      tableSamples,
      sample.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Insert multiple samples
  Future<void> insertSamples(List<Sample> samples) async {
    final db = await database;
    final batch = db.batch();
    for (final sample in samples) {
      batch.insert(
        tableSamples,
        sample.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Get all samples
  Future<List<Sample>> getAllSamples() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples within a time range
  Future<List<Sample>> getSamplesByTimeRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp >= ? AND timestamp <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples since a specific time
  Future<List<Sample>> getSamplesSince(DateTime since) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp > ?',
      whereArgs: [since.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get the most recent sample
  Future<Sample?> getMostRecentSample() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Sample.fromMap(maps.first);
  }

  /// Get sample count
  Future<int> getSampleCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableSamples');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Delete all samples
  Future<void> deleteAllSamples() async {
    final db = await database;
    await db.delete(tableSamples);
  }

  /// Delete samples older than a certain date
  Future<void> deleteSamplesOlderThan(DateTime date) async {
    final db = await database;
    await db.delete(
      tableSamples,
      where: 'timestamp < ?',
      whereArgs: [date.millisecondsSinceEpoch],
    );
  }

  /// Export all samples as JSON
  Future<List<Map<String, dynamic>>> exportSamples() async {
    final samples = await getAllSamples();
    return samples.map((s) => s.toJson()).toList();
  }

  /// Close the database
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
