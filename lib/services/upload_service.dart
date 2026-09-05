import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_service.dart';
import '../models/models.dart';
import '../constants/app_version.dart';

class UploadService {
  bool _isDefaultEndpoint(String url) {
    String norm(String u) {
      var s = u.trim().toLowerCase();
      if (s.endsWith('/')) s = s.substring(0, s.length - 1);
      return s;
    }
    return norm(url) == norm(defaultApiUrl);
  }
  static const String _apiUrlKey = 'upload_api_url';
  static const String _autoUploadKey = 'auto_upload_enabled';
  static const String _lastUploadKey = 'last_upload_timestamp';
  static const String _uploadEndpointsKey = 'upload_endpoints'; // JSON list of endpoints
  static const String _selectedEndpointsKey = 'selected_endpoints'; // JSON list of selected endpoint names
  
  // Default URL (user can change this)
  static const String defaultApiUrl = 'https://meshwar-map.pages.dev/api/samples';
  
  final DatabaseService _db = DatabaseService();
  
  /// Convert a list of samples to the JSON format expected by upload endpoints
  static List<Map<String, dynamic>> _samplesToJson(
    List<Sample> samples, {
    Map<String, String>? repeaterNames,
  }) {
    return samples.map((sample) => {
      'id': sample.id,
      'nodeId': (sample.path == null || sample.path!.isEmpty)
          ? 'Unknown'
          : (sample.path!.toUpperCase()),
///        : (sample.path!.length > 8 ? sample.path!.substring(0, 8).toUpperCase() : sample.path!.toUpperCase()),
      'repeaterName': (() {
        final name = (sample.path != null && repeaterNames != null)
            ? repeaterNames![sample.path]
            : null;
        if (name != null && name.isNotEmpty) return name;
        if (sample.path == null || sample.path!.isEmpty) return 'Unknown';
///        final short = sample.path!.length > 8 ? sample.path!.substring(0,8).toUpperCase() : sample.path!.toUpperCase();
        return sample.path!.toUpperCase();
      })(),
      'latitude': sample.position.latitude,
      'longitude': sample.position.longitude,
      'rssi': sample.rssi,
      'snr': sample.snr,
      'pingSuccess': sample.pingSuccess,
      'timestamp': sample.timestamp.toIso8601String(),
      'appVersion': appVersion,
      if (sample.source != null) 'source': sample.source,
    }).toList();
  }
  
  Future<String> getApiUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiUrlKey) ?? defaultApiUrl;
  }
  
  Future<void> setApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiUrlKey, url);
  }
  
  Future<bool> isAutoUploadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoUploadKey) ?? false;
  }
  
  Future<void> setAutoUploadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoUploadKey, enabled);
  }
  
  Future<DateTime?> getLastUploadTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastUploadKey);
    return timestamp != null ? DateTime.fromMillisecondsSinceEpoch(timestamp) : null;
  }
  
  Future<void> _setLastUploadTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastUploadKey, time.millisecondsSinceEpoch);
  }
  
  /// Upload all unuploaded samples to the configured API
  /// Splits large uploads into batches to avoid timeouts
  Future<UploadResult> uploadAllSamples({
    Map<String, String>? repeaterNames,
    Function(int current, int total)? onProgress,
  }) async {
    try {
      final apiUrl = await getApiUrl();
      final bool isDefault = _isDefaultEndpoint(apiUrl);
      final allSamples = isDefault
          ? await _db.getUnuploadedSamples()
          : await _db.getAllSamples();
      
      // Only upload actual ping samples — GPS-only (pingSuccess=null) samples
      // would be counted as failures by the web map
      var filteredSamples = allSamples.where((s) => s.pingSuccess != null).toList();
      
      // Filter out samples inside privacy zones
      filteredSamples = await _db.filterByPrivacyZones(filteredSamples);
      final samples = filteredSamples;
      
      if (samples.isEmpty) {
        return UploadResult(success: true, message: 'No new samples to upload');
      }
      
      final samplesJson = _samplesToJson(samples, repeaterNames: repeaterNames);
      
      print('Uploading ${samplesJson.length} samples in batches...');
      
      // Split into batches of 100 samples each
      const batchSize = 100;
      final totalBatches = (samplesJson.length / batchSize).ceil();
      int totalCells = 0;
      
      for (int i = 0; i < totalBatches; i++) {
        final start = i * batchSize;
        final end = (start + batchSize < samplesJson.length) 
            ? start + batchSize 
            : samplesJson.length;
        final batch = samplesJson.sublist(start, end);
        
        // Report progress
        if (onProgress != null) {
          onProgress(i + 1, totalBatches);
        }
        
        print('Uploading batch ${i + 1}/$totalBatches (${batch.length} samples)');
        
        // Try up to 2 times (original + 1 retry)
        bool success = false;
        http.Response? response;
        String? error;
        
        for (int attempt = 0; attempt < 2; attempt++) {
          try {
            response = await http.post(
              Uri.parse(apiUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'samples': batch}),
            ).timeout(const Duration(seconds: 60));
            
            if (response.statusCode == 200) {
              success = true;
              final responseData = jsonDecode(response.body);
              totalCells = responseData['totalCells'] ?? totalCells;
              break; // Success, exit retry loop
            } else {
              error = 'Server error: ${response.statusCode}';
              if (attempt == 0) {
                print('Batch ${i + 1} failed with ${response.statusCode}, retrying...');
                await Future.delayed(const Duration(seconds: 2));
              }
            }
          } catch (e) {
            error = e.toString();
            if (attempt == 0) {
              print('Batch ${i + 1} failed: $e, retrying...');
              await Future.delayed(const Duration(seconds: 2));
            }
          }
        }
        
        if (!success) {
          return UploadResult(
            success: false,
            message: 'Failed at batch ${i + 1}/$totalBatches: $error',
          );
        }
      }
      
      // All batches successful
      await _setLastUploadTime(DateTime.now());
      
      // Mark ALL samples (including GPS-only) as uploaded so they don't get re-queried
      final allSampleIds = allSamples.map((s) => s.id).toList();
      if (isDefault) {
        await _db.markSamplesAsUploaded(allSampleIds);
      }
      
      return UploadResult(
        success: true,
        message: 'Upload Complete',
        uploadedCount: samples.length,
        totalCount: totalCells,
      );
    } catch (e) {
      return UploadResult(
        success: false,
        message: 'Upload failed: $e',
      );
    }
  }
  
  /// Upload only samples since last upload (deprecated - use uploadAllSamples instead)
  Future<UploadResult> uploadNewSamples({Map<String, String>? repeaterNames}) async {
    return uploadAllSamples(repeaterNames: repeaterNames);
  }
  
  /// Download community coverage data from a map endpoint.
  /// Returns the parsed coverage map, or null on failure.
  /// Also caches to a local file for offline viewing.
  /// [error] is set with a description if the download fails.
  String? lastDownloadError;
  
  Future<Map<String, dynamic>?> downloadCoverage(String apiUrl, {Function(int current, int total)? onProgress}) async {
    lastDownloadError = null;
    try {
      print('Downloading coverage from: $apiUrl');
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 60));
      
      if (response.statusCode != 200) {
        lastDownloadError = 'Server returned ${response.statusCode}';
        return null;
      }
      
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        lastDownloadError = 'Invalid response format';
        return null;
      }
      
      // --- Sharded format (Cloudflare KV) ---
      if (data.containsKey('shards') && !data.containsKey('coverage')) {
        final shards = data['shards'] as Map<String, dynamic>;
        final prefixes = shards.keys.toList();
        print('Sharded format: ${prefixes.length} shards to fetch');
        
        final allCoverage = <String, dynamic>{};
        
        // Fetch in batches of 10 prefixes
        const batchSize = 10;
        final totalBatches = (prefixes.length / batchSize).ceil();
        
        for (int i = 0; i < totalBatches; i++) {
          final start = i * batchSize;
          final end = (start + batchSize).clamp(0, prefixes.length);
          final batch = prefixes.sublist(start, end);
          
          if (onProgress != null) onProgress(i + 1, totalBatches);
          
          try {
            final batchResp = await http.get(
              Uri.parse('$apiUrl?prefixes=${batch.join(',')}'),
              headers: {'Accept': 'application/json'},
            ).timeout(const Duration(seconds: 30));
            
            if (batchResp.statusCode == 200) {
              final batchData = jsonDecode(batchResp.body);
              if (batchData is Map<String, dynamic> && batchData['coverage'] != null) {
                final cov = batchData['coverage'] as Map<String, dynamic>;
                allCoverage.addAll(cov);
              }
            }
          } catch (e) {
            print('Shard batch ${i+1} failed: $e');
            // Continue with remaining batches
          }
        }
        
        if (allCoverage.isEmpty) {
          lastDownloadError = 'No coverage data received from shards';
          return null;
        }
        
        final result = {'coverage': allCoverage};
        
        // Cache locally
        final dir = await _getAppDir();
        final cacheFile = File('${dir.path}/community_coverage.json');
        await cacheFile.writeAsString(jsonEncode(result));
        
        print('Downloaded ${allCoverage.length} coverage cells from ${prefixes.length} shards');
        return result;
      }
      
      // --- Legacy format (Docker map) ---
      final dir = await _getAppDir();
      final cacheFile = File('${dir.path}/community_coverage.json');
      await cacheFile.writeAsString(response.body);
      
      return data;
    } catch (e) {
      lastDownloadError = e.toString();
      print('Download coverage failed: $e');
      return null;
    }
  }
  
  /// Load cached community coverage from local file
  Future<Map<String, dynamic>?> loadCachedCoverage() async {
    try {
      final dir = await _getAppDir();
      final cacheFile = File('${dir.path}/community_coverage.json');
      if (!await cacheFile.exists()) return null;
      final json = await cacheFile.readAsString();
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
  
  /// Delete cached community coverage
  Future<void> clearCachedCoverage() async {
    final dir = await _getAppDir();
    final cacheFile = File('${dir.path}/community_coverage.json');
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }
  }
  
  Future<Directory> _getAppDir() async {
    return await getApplicationDocumentsDirectory();
  }
  
  /// Get list of configured upload endpoints
  Future<List<UploadEndpoint>> getUploadEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_uploadEndpointsKey);
    
    if (json == null || json.isEmpty) {
      // Return default endpoint
      return [UploadEndpoint(name: 'Default', url: defaultApiUrl)];
    }
    
    final List<dynamic> decoded = jsonDecode(json);
    return decoded.map((e) => UploadEndpoint.fromJson(e as Map<String, dynamic>)).toList();
  }
  
  /// Save upload endpoints
  Future<void> setUploadEndpoints(List<UploadEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(endpoints.map((e) => e.toJson()).toList());
    await prefs.setString(_uploadEndpointsKey, json);
  }
  
  /// Get list of selected endpoint names (for multi-upload)
  Future<List<String>> getSelectedEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_selectedEndpointsKey);
    
    if (json == null || json.isEmpty) {
      return ['Default']; // Default to the default endpoint
    }
    
    final List<dynamic> decoded = jsonDecode(json);
    return decoded.cast<String>();
  }
  
  /// Set selected endpoint names
  Future<void> setSelectedEndpoints(List<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(names);
    await prefs.setString(_selectedEndpointsKey, json);
  }
  
  /// Upload to all selected endpoints
  Future<Map<String, UploadResult>> uploadToSelectedEndpoints({
    Map<String, String>? repeaterNames,
    Function(String endpointName, int current, int total)? onProgress,
  }) async {
    final endpoints = await getUploadEndpoints();
    final selectedNames = await getSelectedEndpoints();
    final results = <String, UploadResult>{};
    
    // Check if any endpoint has samples to upload
    bool hasAnySamples = false;
    for (final endpoint in endpoints) {
      if (selectedNames.contains(endpoint.name)) {
        final samples = await _db.getUnuploadedSamplesForEndpoint(endpoint.url);
        if (samples.isNotEmpty) {
          hasAnySamples = true;
          break;
        }
      }
    }
    
    if (!hasAnySamples) {
      return {'All Sites': UploadResult(success: true, message: 'No new samples to upload')};
    }
    
    // Upload to each selected endpoint
    for (final endpoint in endpoints) {
      if (selectedNames.contains(endpoint.name)) {
        try {
          // Get samples not yet uploaded to this specific endpoint
          final allSamples = await _db.getUnuploadedSamplesForEndpoint(endpoint.url);
          // Only upload actual ping samples — GPS-only inflate failure counts on web map
          final samples = allSamples.where((s) => s.pingSuccess != null).toList();
          
          if (samples.isEmpty) {
            // Still mark GPS-only samples as uploaded so they don't get re-queried
            if (allSamples.isNotEmpty) {
              final ids = allSamples.map((s) => s.id).toList();
              await _db.markSamplesAsUploadedToEndpoint(ids, endpoint.url);
            }
            results[endpoint.name] = UploadResult(
              success: true,
              message: 'No new samples to upload',
            );
            continue;
          }
          
          final result = await _uploadSamplesToEndpoint(
            endpoint.url,
            samples,
            repeaterNames: repeaterNames,
            onProgress: (current, total) {
              if (onProgress != null) {
                onProgress(endpoint.name, current, total);
              }
            },
          );
          
          results[endpoint.name] = result;
          
          // Mark ALL samples (including GPS-only) as uploaded to this endpoint
          if (result.success) {
            final allSampleIds = allSamples.map((s) => s.id).toList();
            await _db.markSamplesAsUploadedToEndpoint(allSampleIds, endpoint.url);
            
            // Also update old uploaded flag for backward compatibility (default endpoint only)
            if (_isDefaultEndpoint(endpoint.url)) {
              await _db.markSamplesAsUploaded(allSampleIds);
            }
          }
        } catch (e) {
          results[endpoint.name] = UploadResult(
            success: false,
            message: 'Upload failed: $e',
          );
        }
      }
    }
    
    return results;
  }
  
  /// Internal method to upload samples to a specific endpoint
  Future<UploadResult> _uploadSamplesToEndpoint(
    String apiUrl,
    List<Sample> samples,
    {Map<String, String>? repeaterNames,
    Function(int current, int total)? onProgress,
  }) async {
    final samplesJson = _samplesToJson(samples, repeaterNames: repeaterNames);
    
    print('Uploading ${samplesJson.length} samples to $apiUrl in batches...');
    
    // Split into batches of 100 samples each
    const batchSize = 100;
    final totalBatches = (samplesJson.length / batchSize).ceil();
    int totalCells = 0;
    
    for (int i = 0; i < totalBatches; i++) {
      final start = i * batchSize;
      final end = (start + batchSize < samplesJson.length) 
          ? start + batchSize 
          : samplesJson.length;
      final batch = samplesJson.sublist(start, end);
      
      // Report progress
      if (onProgress != null) {
        onProgress(i + 1, totalBatches);
      }
      
      print('Uploading batch ${i + 1}/$totalBatches (${batch.length} samples)');
      
      // Try up to 2 times (original + 1 retry)
      bool success = false;
      http.Response? response;
      String? error;
      
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          response = await http.post(
            Uri.parse(apiUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'samples': batch}),
          ).timeout(const Duration(seconds: 60));
          
          if (response.statusCode == 200) {
            success = true;
            final responseData = jsonDecode(response.body);
            totalCells = responseData['totalCells'] ?? totalCells;
            break; // Success, exit retry loop
          } else {
            error = 'Server error: ${response.statusCode}';
            if (attempt == 0) {
              print('Batch ${i + 1} failed with ${response.statusCode}, retrying...');
              await Future.delayed(const Duration(seconds: 2));
            }
          }
        } catch (e) {
          error = e.toString();
          if (attempt == 0) {
            print('Batch ${i + 1} failed: $e, retrying...');
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }
      
      if (!success) {
        return UploadResult(
          success: false,
          message: 'Failed at batch ${i + 1}/$totalBatches: $error',
        );
      }
    }
    
    // All batches successful
    await _setLastUploadTime(DateTime.now());
    
    return UploadResult(
      success: true,
      message: 'Upload Complete',
      uploadedCount: samples.length,
      totalCount: totalCells,
    );
  }
}

class UploadEndpoint {
  final String name;
  final String url;
  
  UploadEndpoint({
    required this.name,
    required this.url,
  });
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
  };
  
  factory UploadEndpoint.fromJson(Map<String, dynamic> json) {
    return UploadEndpoint(
      name: json['name'] as String,
      url: json['url'] as String,
    );
  }
}

class UploadResult {
  final bool success;
  final String message;
  final int? uploadedCount;
  final int? totalCount;
  
  UploadResult({
    required this.success,
    required this.message,
    this.uploadedCount,
    this.totalCount,
  });
}
