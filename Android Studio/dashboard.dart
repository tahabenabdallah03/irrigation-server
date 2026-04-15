import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:smart_irrigation_app/screens/history_screen.dart';
import 'package:smart_irrigation_app/screens/login_screen.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum _UiLanguage { fr, en }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.sessionToken});

  final String? sessionToken;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  static const String baseUrl =
      'https://bug-free-doodle-x57rv64rpp67cvrq5-8080.app.github.dev';
  static const String _zoneOverridesStorageKey =
      'zone_overrides_v1';
  static const String _languageStorageKey = 'ui_language_v1';
  static const String _dosageConfigStorageKey = 'dosage_products_config_v1';
  static const Duration _zoneNamePinDuration = Duration(seconds: 45);

  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();
  final PageController _pageController = PageController();
  final ScrollController _mainScrollController = ScrollController();
  final GlobalKey _zoneSectionKey = GlobalKey();
  final FlutterLocalNotificationsPlugin notificationsPlugin =
  FlutterLocalNotificationsPlugin();

  io.Socket? socket;
  Timer? _dashboardSyncTimer;
  Timer? _zonesConsistencyTimer;
  bool _dashboardSyncInFlight = false;
  bool _snapshotSyncInFlight = false;
  bool _showBottomActions = false;
  DateTime? _lastZonesRealtimeAt;
  DateTime? _lastZoneConfigSyncAt;
  DateTime? _suppressReactiveRefreshUntil;
  String? token;
  bool isLoggingOut = false;

  Map<String, dynamic> environment = {};
  List<Map<String, dynamic>> zones = [];
  Map<int, List<Map<String, dynamic>>> alertsHistory = {};
  final Map<String, bool> lastNotification = {};
  final Map<int, Map<String, bool>> _thresholdPermissionOverridesByZoneId = {};
  final Map<String, Map<String, bool>> _pendingThresholdPermissionsByZoneName = {};
  final Map<int, _ZoneNamePin> _zoneNamePinsById = {};
  int? selectedZoneId;
  int currentZoneIndex = 0;
  int currentLandscapePage = 0;
  DateTime? _lastLandscapeAutoAdvanceAt;
  _UiLanguage _uiLanguage = _UiLanguage.fr;
  Map<String, dynamic>? _dosagePlan;
  double? _tankCapacityLiters;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mainScrollController.addListener(_updateBottomActionsVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateBottomActionsVisibility();
    });
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashboardSyncTimer?.cancel();
    _zonesConsistencyTimer?.cancel();
    socket?.dispose();
    _pageController.dispose();
    _mainScrollController.removeListener(_updateBottomActionsVisibility);
    _mainScrollController.dispose();
    super.dispose();
  }

  void _updateBottomActionsVisibility() {
    if (!_mainScrollController.hasClients) {
      if (_showBottomActions) {
        setState(() {
          _showBottomActions = false;
        });
      }
      return;
    }

    // Show actions only when user reaches the end of dashboard scroll.
    final shouldShow = _mainScrollController.position.extentAfter <= 24;
    if (shouldShow == _showBottomActions) return;

    setState(() {
      _showBottomActions = shouldShow;
    });
  }

  void _markLocalUiAction() {
    _suppressReactiveRefreshUntil =
        DateTime.now().add(const Duration(milliseconds: 4000));
  }

  bool _isReactiveRefreshSuppressed() {
    final until = _suppressReactiveRefreshUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _suppressReactiveRefreshUntil = null;
      return false;
    }
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && token != null && token!.isNotEmpty) {
      _restartDashboardSyncTimer();
      _fetchDashboardSnapshot();
      _fetchZoneConfig();
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _dashboardSyncTimer?.cancel();
      _zonesConsistencyTimer?.cancel();
    }
  }

  Future<void> _openHistory() async {
    if (token == null || token!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_tr('Session invalide. Veuillez vous reconnecter.', 'Invalid session. Please log in again.')),
        ),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryScreen(token: token!, isEnglish: _isEnglish),
      ),
    );
  }

  Future<void> _openDosageSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _DosageSettingsScreen(
          isEnglish: _isEnglish,
          storageKey: _dosageConfigStorageKey,
          baseUrl: baseUrl,
          token: token,
          initialDosagePlan: _dosagePlan,
        ),
      ),
    );
  }

  Future<void> _logout() async {
    if (isLoggingOut) return;
    isLoggingOut = true;

    _dashboardSyncTimer?.cancel();
    _zonesConsistencyTimer?.cancel();
    await secureStorage.delete(key: 'token');
    socket?.dispose();

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
    );
  }

  Future<void> _scrollToZoneSection() async {
    if (!mounted) return;
    final ctx = _zoneSectionKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.1,
      );
      return;
    }

    if (_mainScrollController.hasClients) {
      await _mainScrollController.animateTo(
        240,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _bootstrap() async {
    await _initNotifications();

    token = widget.sessionToken;
    token ??= await secureStorage.read(key: 'token');
    if (token == null || token!.trim().isEmpty) {
      await _handleUnauthorized(_tr('Session absente. Veuillez vous reconnecter.', 'Missing session. Please log in again.'));
      return;
    }

    _restartDashboardSyncTimer();
    await _loadLanguagePreference();
    await _loadZoneOverridesLocally();

    _connectSocket();
    await _fetchDashboardSnapshot();
    await _fetchZoneConfig();
    await _fetchAlertsSnapshot();
  }

  bool get _isEnglish => _uiLanguage == _UiLanguage.en;

  String _tr(String fr, String en) => _isEnglish ? en : fr;

  Future<void> _loadLanguagePreference() async {
    final raw = await secureStorage.read(key: _languageStorageKey);
    final nextLanguage = raw == 'en' ? _UiLanguage.en : _UiLanguage.fr;
    if (!mounted) {
      _uiLanguage = nextLanguage;
      return;
    }
    setState(() {
      _uiLanguage = nextLanguage;
    });
  }

  Future<void> _setLanguage(_UiLanguage language) async {
    if (_uiLanguage == language) return;
    await secureStorage.write(
      key: _languageStorageKey,
      value: language == _UiLanguage.en ? 'en' : 'fr',
    );
    if (!mounted) return;
    setState(() {
      _uiLanguage = language;
    });
  }

  Future<void> _showLanguageDialog() async {
    final selected = await showDialog<_UiLanguage>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr('Choisir la langue', 'Choose language')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<_UiLanguage>(
              value: _UiLanguage.fr,
              groupValue: _uiLanguage,
              title: const Text('Français'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
            RadioListTile<_UiLanguage>(
              value: _UiLanguage.en,
              groupValue: _uiLanguage,
              title: const Text('English'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
      ),
    );

    if (selected == null) return;
    await _setLanguage(selected);
  }

  Future<void> _loadZoneOverridesLocally() async {
    try {
      final raw = await secureStorage.read(key: _zoneOverridesStorageKey);
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final loadedById = <int, Map<String, bool>>{};
      final loadedByName = <String, Map<String, bool>>{};

      final byIdRaw = decoded['byId'];
      if (byIdRaw is Map) {
        for (final entry in byIdRaw.entries) {
          final id = int.tryParse(entry.key.toString());
          if (id == null || entry.value is! Map) continue;

          final boolMap = <String, bool>{};
          for (final item in (entry.value as Map).entries) {
            boolMap[item.key.toString()] = _toBool(item.value, fallback: false);
          }
          loadedById[id] = boolMap;
        }
      }

      final byNameRaw = decoded['byName'];
      if (byNameRaw is Map) {
        for (final entry in byNameRaw.entries) {
          if (entry.value is! Map) continue;

          final boolMap = <String, bool>{};
          for (final item in (entry.value as Map).entries) {
            boolMap[item.key.toString()] = _toBool(item.value, fallback: false);
          }
          loadedByName[entry.key.toString()] = boolMap;
        }
      }

      _thresholdPermissionOverridesByZoneId
        ..clear()
        ..addAll(loadedById);
      _pendingThresholdPermissionsByZoneName
        ..clear()
        ..addAll(loadedByName);
    } catch (e) {
      debugPrint('Load local zone overrides error: $e');
    }
  }

  Future<void> _saveZoneOverridesLocally() async {
    try {
      final payload = {
        'byId': _thresholdPermissionOverridesByZoneId
            .map((key, value) => MapEntry(key.toString(), value)),
        'byName': _pendingThresholdPermissionsByZoneName,
      };
      await secureStorage.write(
        key: _zoneOverridesStorageKey,
        value: jsonEncode(payload),
      );
    } catch (e) {
      debugPrint('Save local zone overrides error: $e');
    }
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidSettings =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings settings =
    InitializationSettings(android: androidSettings);

    await notificationsPlugin.initialize(settings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'zone_alert_channel',
      'Zone Alerts',
      description: 'Notifications des alertes de zones',
      importance: Importance.max,
    );

    final androidPlugin = notificationsPlugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(channel);
  }

  Future<void> _showAlertNotification(String title, String message) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'zone_alert_channel',
      'Zone Alerts',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );

    const NotificationDetails details =
    NotificationDetails(android: androidDetails);

    await notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      message,
      details,
    );
  }

  String _resolveZoneNotificationTitle(int zoneId, Map<String, dynamic> alert) {
    final payloadName = (alert['zone_name'] ?? alert['zoneName'] ?? '').toString().trim();
    if (payloadName.isNotEmpty) {
      return _tr('Alerte zone $zoneId : $payloadName', 'Zone alert $zoneId: $payloadName');
    }

    final idx = zones.indexWhere((z) => _toInt(z['id']) == zoneId);
    if (idx >= 0) {
      return _tr('Alerte zone $zoneId : ${zoneLabel(zones[idx])}', 'Zone alert $zoneId: ${zoneLabel(zones[idx])}');
    }

    return _tr('Alerte zone $zoneId', 'Zone alert $zoneId');
  }

  List<String> _splitAlertLines(String? rawMessage) {
    final raw = (rawMessage ?? '').toString();
    if (raw.trim().isEmpty) return const [];

    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_translateAlertLine)
        .toList();

    if (lines.isNotEmpty) return lines;
    return [_translateAlertLine(raw.trim())];
  }

  String _normalizeAlertText(String value) {
    return value
        .toLowerCase()
        .trim()
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ä', 'a')
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ö', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ç', 'c');
  }

  String _translateAlertLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) return line;

    final normalized = _normalizeAlertText(line);

    if (normalized.contains('rapid') && normalized.contains('evaporation')) {
      return _tr('Risque évaporation rapide', 'Risk of rapid evaporation');
    }

    if ((normalized.contains('urgent') && normalized.contains('irrigation')) ||
        (normalized.contains('alerte') && normalized.contains('irrigation urgente'))) {
      return _tr('Alerte : irrigation urgente', 'Urgent irrigation needed');
    }

    if (normalized.contains('temperature') &&
        (normalized.contains('eleve') || normalized.contains('high'))) {
      return _tr('Alerte : temperature elevée', 'Alert : High temperature');
    }

    if ((normalized.contains('gaz') || normalized.contains('gas')) &&
        (normalized.contains('detect') || normalized.contains('detected'))) {
      return _tr('Alerte : gaz detectée', 'Alert: Gas detected');
    }

    return line;
  }

  String _translateAlertMessage(String rawMessage) {
    final lines = _splitAlertLines(rawMessage);
    if (lines.isEmpty) return '';
    return lines.join('\n');
  }

  Map<String, String> _authHeaders() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    };
  }

  String _normalizeZoneNameKey(String raw) {
    return raw.trim().toLowerCase();
  }

  bool _isZoneNameAlreadyUsed(String rawName, {int? excludeZoneId}) {
    final candidate = _normalizeZoneNameKey(rawName);
    if (candidate.isEmpty) return false;

    for (final zone in zones) {
      final zoneId = _toInt(zone['id'], fallback: -1);
      if (excludeZoneId != null && zoneId == excludeZoneId) continue;

      final existingNameRaw = (zone['name'] ?? zoneLabel(zone)).toString().trim();
      if (existingNameRaw.isEmpty) continue;

      if (_normalizeZoneNameKey(existingNameRaw) == candidate) {
        return true;
      }
    }

    return false;
  }

  String? _extractApiErrorMessage(http.Response? response) {
    if (response == null) return null;

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final error =
            (decoded['error'] ?? decoded['message'] ?? '').toString().trim();
        if (error.isNotEmpty) return error;
      }
    } catch (_) {}

    return null;
  }

  Future<http.Response?> _authorizedGet(String path) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl$path'), headers: _authHeaders())
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 401) {
        await _handleUnauthorized(_tr('Session expiree. Veuillez vous reconnecter.', 'Session expired. Please log in again.'));
        return null;
      }

      return res;
    } catch (e) {
      debugPrint('GET error $path : $e');
      return null;
    }
  }

  Future<http.Response?> _authorizedPost(
      String path, {
        Map<String, dynamic>? body,
      }) async {
    try {
      final res = await http
          .post(
        Uri.parse('$baseUrl$path'),
        headers: _authHeaders(),
        body: jsonEncode(body ?? <String, dynamic>{}),
      )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 401) {
        await _handleUnauthorized(_tr('Session expiree. Veuillez vous reconnecter.', 'Session expired. Please log in again.'));
        return null;
      }

      return res;
    } catch (e) {
      debugPrint('POST error $path : $e');
      return null;
    }
  }

  Future<http.Response?> _postFirstSuccessful(
      List<String> paths, {
        Map<String, dynamic>? body,
      }) async {
    http.Response? lastResponse;
    for (final path in paths) {
      final res = await _authorizedPost(path, body: body);
      lastResponse = res;
      if (res != null && res.statusCode < 400) return res;
    }
    return lastResponse;
  }

  Future<bool> _syncZoneConfig({bool showError = false}) async {
    final payload = _buildZoneConfigPayload();
    final response = await _authorizedPost(
      '/sync-zone-config',
      body: {'zone_config': payload},
    );

    final ok = response != null && response.statusCode < 400;
    if (!ok && showError && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec sync zone_config', 'Failed to sync zone_config'))),
      );
      return false;
    }

    await _fetchZoneConfig();
    return ok;
  }

  Future<bool> _syncZoneRuntime(
      int zoneId,
      bool evState, {
        bool showError = false,
      }) async {
    final response = await _authorizedPost(
      '/command',
      body: {
        'zone': zoneId,
        'zone_id': zoneId,
        'zoneId': zoneId,
        'mode': 'MANUAL',
        'ev_state': evState,
        'evState': evState,
        'valve': evState,
        'valve_on': evState,
        'state': evState ? 'ON' : 'OFF',
      },
    );

    final ok = response != null && response.statusCode < 400;
    if (!ok && showError && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec sync zone_runtime', 'Failed to sync zone_runtime'))),
      );
    }

    return ok;
  }

  List<Map<String, dynamic>> _buildZoneConfigPayload() {
    final source = zones
        .map(
          (zone) => <String, dynamic>{
        'id': _toInt(zone['id']),
        'name': zoneLabel(zone),
        'seuil_light': _toDouble(zone['thresholdLight']),
        'seuil_hum': _toDouble(zone['thresholdHumidity']),
        'seuil_gaz': _toDouble(zone['thresholdgaz'] ?? zone['thresholdGaz'] ?? zone['thresholdNutrition']),
        'seuil_temp': _toDouble(zone['thresholdTemperature']),
        'ev_mode': _isManualMode(zone['ev_mode']) ? 'MANUAL' : 'AUTO',
        'use_hum': _toBool(zone['use_hum'], fallback: _usesHumiditySensor(zone)),
        'use_temp': _toBool(zone['use_temp'], fallback: _usesTemperatureSensor(zone)),
        'use_gaz': _toBool(zone['use_gaz'], fallback: _usesGasSensor(zone)),
        'use_light': _toBool(zone['use_light'], fallback: _usesLightSensor(zone)),
        'use_ev': _toBool(zone['use_ev'], fallback: _canControlValve(zone)),
      },
    )
        .toList();

    source.sort((a, b) => _toInt(a['id']).compareTo(_toInt(b['id'])));
    return source;
  }

  List<Map<String, dynamic>> _buildZoneRuntimePayload(int zoneId, bool evState) {
    return [
      {
        'id': zoneId,
        'zone_id': zoneId,
        'zoneId': zoneId,
        'ev_state': evState,
        'evState': evState,
        'valve': evState ? 1 : 0,
        'valve_on': evState,
        'state': evState ? 'ON' : 'OFF',
      },
    ];
  }

  Future<void> _handleUnauthorized(String message) async {
    if (isLoggingOut) return;
    isLoggingOut = true;

    _dashboardSyncTimer?.cancel();
    _zonesConsistencyTimer?.cancel();
    await secureStorage.delete(key: 'token');
    socket?.dispose();

    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message)),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
            (_) => false,
      );
    });
  }

  void _connectSocket() {
    if (token == null || token!.isEmpty) return;

    socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .build(),
    );

    socket!.onConnect((_) {
      debugPrint('Socket connected');
      _fetchDashboardSnapshot();
      _fetchZoneConfig();
    });

    socket!.onConnectError((data) async {
      final text = data.toString().toLowerCase();
      if (text.contains('invalid token') || text.contains('missing bearer')) {
        await _handleUnauthorized(_tr('Session socket invalide.', 'Invalid socket session.'));
      }
    });

    socket!.on('environment-update', (data) {
      if (data is! Map) return;
      if (!mounted) return;

      setState(() {
        environment = Map<String, dynamic>.from(data);
      });
    });

    socket!.on('zones-update', (data) {
      if (data is! List) return;

      final incoming = data
          .whereType<Map>()
          .map((e) => _normalizeZone(Map<String, dynamic>.from(e)))
          .toList();

      incoming.sort((a, b) => _toInt(a['id']).compareTo(_toInt(b['id'])));

      if (!mounted) return;

      setState(() {
        _lastZonesRealtimeAt = DateTime.now();
        zones = incoming;
        _clampLandscapePage();

        if (zones.isEmpty) {
          selectedZoneId = null;
          currentZoneIndex = 0;
          return;
        }

        final stillExists =
        zones.any((z) => _toInt(z['id']) == (selectedZoneId ?? -1));

        if (!stillExists) {
          selectedZoneId = _toInt(zones.first['id']);
          currentZoneIndex = 0;
        } else {
          final idx = zones.indexWhere((z) => _toInt(z['id']) == selectedZoneId);
          if (idx >= 0) currentZoneIndex = idx;
        }
      });

      // Avoid an immediate forced HTTP snapshot after socket update:
      // this extra refresh causes visible UI jitter/reload effects.
      // Realtime socket data is already applied above, and periodic fallback
      // still protects against stale states.
    });

    socket!.on('zone-config-update', (_) async {
      // Config-only event: keep it lightweight, runtime state is carried by zones-update.
      if (_isReactiveRefreshSuppressed()) return;
      await _fetchZoneConfig();
    });

    socket!.on('zone-alert', (data) {
      final alerts = data is List ? data : [data];
      if (alerts.isEmpty) return;

      for (final raw in alerts) {
        if (raw is! Map) continue;

        final a = Map<String, dynamic>.from(raw);
        if (!_isLabViewAlert(a)) continue;

        final zoneId = _toInt(
          a['zone_id'] ?? a['zoneId'] ?? a['zone'] ?? a['id'],
          fallback: -1,
        );
        if (zoneId <= 0) continue;

        final message = (a['message'] ?? '').toString().trim();
        final alertLines = _splitAlertLines(message);
        if (alertLines.isEmpty) continue;

        final createdAt = (a['created_at'] ?? '').toString();
        final notificationTitle = _resolveZoneNotificationTitle(zoneId, a);
        for (final line in alertLines) {
          final key = '$zoneId-$createdAt-$line';
          if (lastNotification.containsKey(key)) continue;
          _showAlertNotification(notificationTitle, line);
          lastNotification[key] = true;
        }

        if (!mounted) return;

        setState(() {
          alertsHistory.putIfAbsent(zoneId, () => []);
          for (final line in alertLines.reversed) {
            final splitAlert = Map<String, dynamic>.from(a);
            splitAlert['message'] = line;
            alertsHistory[zoneId]!.insert(0, splitAlert);
          }

          final idx = zones.indexWhere((z) => _toInt(z['id']) == zoneId);
          if (idx >= 0) {
            zones[idx]['latest_alert_message'] = alertLines.join('\n');
            zones[idx]['latest_alert_level'] =
                (a['level'] ?? 'WARNING').toString().toUpperCase();
          }
        });
      }
    });
  }

  void _restartDashboardSyncTimer() {
    _dashboardSyncTimer?.cancel();
    _dashboardSyncInFlight = false;

    // Fast loop with adaptive fallback:
    // - if realtime socket updates are fresh, do nothing
    // - if realtime stalls, pull snapshot quickly
    _dashboardSyncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _runAdaptiveFallbackSync();
    });
  }

  Future<void> _runAdaptiveFallbackSync() async {
    if (!mounted) return;
    if (token == null || token!.isEmpty) return;
    if (_dashboardSyncInFlight) return;

    final now = DateTime.now();
    final realtimeFresh = _lastZonesRealtimeAt != null &&
        now.difference(_lastZonesRealtimeAt!) < const Duration(seconds: 8);
    if (realtimeFresh) return;

    _dashboardSyncInFlight = true;
    try {
      await _fetchDashboardSnapshot();

      final shouldRefreshConfig = _lastZoneConfigSyncAt == null ||
          now.difference(_lastZoneConfigSyncAt!) >= const Duration(seconds: 12);
      if (shouldRefreshConfig) {
        await _fetchZoneConfig();
        _lastZoneConfigSyncAt = DateTime.now();
      }
    } finally {
      _dashboardSyncInFlight = false;
    }
  }

  void _scheduleImmediateConsistencySync() {
    _zonesConsistencyTimer?.cancel();
    _zonesConsistencyTimer = Timer(const Duration(milliseconds: 120), () async {
      if (!mounted) return;
      if (token == null || token!.isEmpty) return;
      if (_snapshotSyncInFlight) return;

      _snapshotSyncInFlight = true;
      try {
        await _fetchDashboardSnapshot();
      } finally {
        _snapshotSyncInFlight = false;
      }
    });
  }

  Future<void> _fetchDashboardSnapshot() async {
    final response = await _authorizedGet('/dashboard');
    if (response == null || response.statusCode != 200) return;

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final env = Map<String, dynamic>.from(body['environment'] ?? {});
    final dosagePlanRaw = body['dosage_plan'];
    final parsedDosagePlan = dosagePlanRaw is Map
      ? Map<String, dynamic>.from(dosagePlanRaw)
      : null;
    final parsedTankCapacityLiters =
        _toPositiveDoubleOrNull(body['tank_capacity_liters']) ??
        _toPositiveDoubleOrNull(parsedDosagePlan?['tank_capacity_liters']);
    var incoming = ((body['zones'] ?? []) as List)
        .whereType<Map>()
        .map((e) => _normalizeZone(Map<String, dynamic>.from(e)))
        .toList();

    incoming = _mergeZoneConfigWithBase(incoming, body['zone_config']);

    incoming.sort((a, b) => _toInt(a['id']).compareTo(_toInt(b['id'])));

    if (!mounted) return;
    setState(() {
      environment = env;
      _dosagePlan = parsedDosagePlan;
      _tankCapacityLiters = parsedTankCapacityLiters ?? _tankCapacityLiters;
      zones = incoming;
      _clampLandscapePage();

      if (zones.isNotEmpty) {
        selectedZoneId ??= _toInt(zones.first['id']);
        final idx = zones.indexWhere((z) => _toInt(z['id']) == selectedZoneId);
        currentZoneIndex = idx >= 0 ? idx : 0;
        selectedZoneId = _toInt(zones[currentZoneIndex]['id']);
      }
    });
  }

  Future<void> _fetchZoneConfig() async {
    http.Response? response = await _authorizedGet('/zone-config');
    dynamic body;

    if (response == null || response.statusCode != 200) {
      response = await _authorizedGet('/dashboard');
      if (response == null || response.statusCode != 200) return;
    }

    try {
      body = jsonDecode(response.body);
    } catch (_) {
      return;
    }

    final merged = _mergeZoneConfigWithBase(zones, body);
    if (!mounted || merged.isEmpty) return;

    setState(() {
      zones = merged;
      _clampLandscapePage();
      if (zones.isEmpty) {
        selectedZoneId = null;
        currentZoneIndex = 0;
        return;
      }
      final idx = zones.indexWhere((z) => _toInt(z['id']) == selectedZoneId);
      if (idx >= 0) {
        currentZoneIndex = idx;
      } else {
        selectedZoneId = _toInt(zones.first['id']);
        currentZoneIndex = 0;
      }
    });
  }

  List<Map<String, dynamic>> _mergeZoneConfigWithBase(
      List<Map<String, dynamic>> baseZones,
      dynamic source,
      ) {
    final zoneConfigList = _extractZoneConfigList(source);
    if (zoneConfigList.isEmpty) {
      return List<Map<String, dynamic>>.from(baseZones);
    }

    final byId = <int, Map<String, dynamic>>{};
    for (final zone in baseZones) {
      byId[_toInt(zone['id'])] = Map<String, dynamic>.from(zone);
    }

    for (final item in zoneConfigList) {
      final id = _toInt(item['id'], fallback: -1);
      if (id <= 0) continue;

      final current = byId[id] ?? <String, dynamic>{'id': id};
      final incomingName = (item['name'] ?? item['String'] ?? '').toString().trim();
      final candidateName = incomingName.isNotEmpty
          ? incomingName
          : (current['name'] ?? '').toString().trim();
      final mergedRaw = {
        ...current,
        'id': id,
        'name': _applyPinnedZoneName(
          id,
          candidateName.isEmpty ? 'Zone $id' : candidateName,
        ),
        'thresholdHumidity': _toDouble(
          item['seuil_hum'] ?? item['thresholdHumidity'] ?? current['thresholdHumidity'],
          fallback: _toDouble(current['thresholdHumidity'], fallback: 30),
        ),
        'thresholdTemperature': _toDouble(
          item['seuil_temp'] ??
              item['thresholdTemperature'] ??
              current['thresholdTemperature'],
          fallback: _toDouble(current['thresholdTemperature'], fallback: 25),
        ),
        'thresholdNutrition': _toDouble(
          item['seuil_gaz'] ?? item['thresholdNutrition'] ?? current['thresholdNutrition'],
          fallback: _toDouble(current['thresholdNutrition'], fallback: 50),
        ),
        'thresholdLight': _toDouble(
          item['seuil_light'] ?? item['thresholdLight'] ?? current['thresholdLight'],
          fallback: _toDouble(current['thresholdLight'], fallback: 200),
        ),
        'useHumiditySensor': _toBool(
          item['use_hum'] ?? item['useHumiditySensor'] ?? current['useHumiditySensor'],
          fallback: _usesHumiditySensor(current),
        ),
        'useTemperatureSensor': _toBool(
          item['use_temp'] ?? item['useTemperatureSensor'] ?? current['useTemperatureSensor'],
          fallback: _usesTemperatureSensor(current),
        ),
        'useGasSensor': _toBool(
          item['use_gaz'] ?? item['useGasSensor'] ?? current['useGasSensor'],
          fallback: _usesGasSensor(current),
        ),
        'useLightSensor': _toBool(
          item['use_light'] ?? item['useLightSensor'] ?? current['useLightSensor'],
          fallback: _usesLightSensor(current),
        ),
      };

      final useEv = _toBool(
        item['use_ev'] ?? item['allowValveControl'] ?? current['allowValveControl'],
        fallback: _canControlValve(current),
      );
      final rawMode = item['ev_mode'];
      final modeBool = (rawMode == null || rawMode.toString().trim().isEmpty)
          ? _isManualMode(current['ev_mode'])
          : _isManualMode(rawMode);
      mergedRaw['allowValveControl'] = useEv;
      mergedRaw['use_hum'] = _toBool(mergedRaw['useHumiditySensor']);
      mergedRaw['use_temp'] = _toBool(mergedRaw['useTemperatureSensor']);
      mergedRaw['use_gaz'] = _toBool(mergedRaw['useGasSensor']);
      mergedRaw['use_light'] = _toBool(mergedRaw['useLightSensor']);
      mergedRaw['use_ev'] = useEv;
      mergedRaw['allowThresholdEdit'] =
          _toBool(mergedRaw['useHumiditySensor']) ||
              _toBool(mergedRaw['useTemperatureSensor']) ||
              _toBool(mergedRaw['useGasSensor']) ||
              _toBool(mergedRaw['useLightSensor']);
      mergedRaw['allowHumidityThresholdEdit'] = _toBool(mergedRaw['useHumiditySensor']);
      mergedRaw['allowTemperatureThresholdEdit'] = _toBool(mergedRaw['useTemperatureSensor']);
      mergedRaw['allowGasThresholdEdit'] = _toBool(mergedRaw['useGasSensor']);
      mergedRaw['allowLightThresholdEdit'] = _toBool(mergedRaw['useLightSensor']);
      mergedRaw['ev_mode'] = modeBool ? 'MANUAL' : 'AUTO';

      byId[id] = _normalizeZone(mergedRaw, applyLocalOverrides: false);
    }

    final merged = byId.values.toList()
      ..sort((a, b) => _toInt(a['id']).compareTo(_toInt(b['id'])));
    return merged;
  }

  List<Map<String, dynamic>> _extractZoneConfigList(dynamic source) {
    dynamic raw = source;
    if (raw is Map && raw.containsKey('zone_config')) {
      raw = raw['zone_config'];
    }

    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    if (raw is Map && raw.containsKey('id')) {
      return [Map<String, dynamic>.from(raw)];
    }

    return const [];
  }

  Future<void> _fetchAlertsSnapshot() async {
    final response = await _authorizedGet('/alerts');
    if (response == null || response.statusCode != 200) return;

    final parsed = jsonDecode(response.body);
    if (parsed is! List) return;

    final grouped = <int, List<Map<String, dynamic>>>{};
    for (final raw in parsed) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (!_isLabViewAlert(item)) continue;
      final zoneId = _toInt(item['zone_id'], fallback: -1);
      if (zoneId <= 0) continue;
      grouped.putIfAbsent(zoneId, () => []);
      grouped[zoneId]!.add(item);
    }

    if (!mounted) return;
    setState(() {
      alertsHistory = grouped;

      // Keep UI alert state aligned with active alert fields from backend snapshot.
      for (final zone in zones) {
        final zoneId = _toInt(zone['id'], fallback: -1);
        final latest = _resolveLatestAlert(zoneId, zone);
        if (latest == null) {
          zone['latest_alert_message'] = '';
          zone['latest_alert_level'] = 'WARNING';
          continue;
        }

        zone['latest_alert_message'] = latest['message'];
        zone['latest_alert_level'] = latest['level'];
      }
    });
  }

  Map<String, String>? _resolveLatestAlert(int zoneId, [Map<String, dynamic>? zone]) {
    // Dashboard should display only currently active alert, not historical one.
    final activeMessage = (zone?['latest_alert_message'] ?? '').toString().trim();
    if (activeMessage.isNotEmpty) {
      return {
        'message': _translateAlertMessage(activeMessage),
        'level': (zone?['latest_alert_level'] ?? 'WARNING')
            .toString()
            .trim()
            .toUpperCase(),
      };
    }

    // No active alert for this zone.
    return null;

    /*
    final history = alertsHistory[zoneId];
    if (history == null || history.isEmpty) return null;

    Map<String, dynamic>? latest;
    DateTime? latestTime;

    for (final item in history) {
      final msg = (item['message'] ?? '').toString().trim();
      if (msg.isEmpty) continue;

      final createdRaw = (item['created_at'] ?? item['timestamp'] ?? '').toString();
      final createdAt = DateTime.tryParse(createdRaw);

      if (latest == null) {
        latest = item;
        latestTime = createdAt;
        continue;
      }

      if (createdAt != null && (latestTime == null || createdAt.isAfter(latestTime))) {
        latest = item;
        latestTime = createdAt;
      }
    }

    if (latest == null) return null;

    return {
      'message': (latest['message'] ?? '').toString().trim(),
      'level': (latest['level'] ?? 'WARNING').toString().trim().toUpperCase(),
    };
    */
  }

  bool _isLabViewAlert(Map<String, dynamic> alert) {
    final source = (alert['source'] ?? alert['origin'] ?? alert['producer'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    // When source is provided, keep only LabVIEW-origin alerts.
    if (source.isNotEmpty) {
      return source.contains('labview');
    }

    // Fallback: treat socket/event alerts as valid if they carry a non-empty message.
    final message = (alert['message'] ?? '').toString().trim();
    return message.isNotEmpty;
  }

  void _pinZoneName(int zoneId, String zoneName) {
    final trimmed = zoneName.trim();
    if (zoneId <= 0 || trimmed.isEmpty) return;
    _zoneNamePinsById[zoneId] = _ZoneNamePin(
      name: trimmed,
      expiresAt: DateTime.now().add(_zoneNamePinDuration),
    );
  }

  String _applyPinnedZoneName(int zoneId, String incomingName) {
    if (zoneId <= 0) return incomingName;

    final pin = _zoneNamePinsById[zoneId];
    if (pin == null) return incomingName;

    if (DateTime.now().isAfter(pin.expiresAt)) {
      _zoneNamePinsById.remove(zoneId);
      return incomingName;
    }

    final trimmedIncoming = incomingName.trim();
    if (trimmedIncoming.toLowerCase() == pin.name.toLowerCase()) {
      _zoneNamePinsById.remove(zoneId);
      return trimmedIncoming;
    }

    return pin.name;
  }

  Map<String, dynamic> _normalizeZone(
      Map<String, dynamic> z, {
        bool applyLocalOverrides = true,
      }) {
    final id = _toInt(z['id']);
    final nameRaw = (z['name'] ?? '').toString().trim();
    final displayName = _applyPinnedZoneName(
      id,
      nameRaw.isEmpty ? 'Zone $id' : nameRaw,
    );

    final enabledSensorsRaw = z['enabledSensors'] ?? z['enabled_sensors'];
    final enabledSensors = enabledSensorsRaw is List
        ? enabledSensorsRaw.map((e) => e.toString().trim().toLowerCase()).toSet()
        : <String>{};

    final useHumiditySensor = enabledSensors.contains('humidity')
        ? true
        : _toBool(
      z['useHumiditySensor'] ??
          z['use_hum'] ??
          z['useHum'] ??
          z['use_humidity_sensor'] ??
          z['hasHumiditySensor'] ??
          z['has_humidity_sensor'],
      fallback: _toBool(
        z['allowHumidityThresholdEdit'] ??
            z['allow_humidity_threshold_edit'] ??
            z['canEditHumidityThreshold'] ??
            z['can_edit_humidity_threshold'],
        fallback: true,
      ),
    );
    final useGasSensor = enabledSensors.contains('gas')
        ? true
        : _toBool(
      z['useGasSensor'] ??
          z['use_gaz'] ??
          z['useGaz'] ??
          z['use_gas_sensor'] ??
          z['hasGasSensor'] ??
          z['has_gas_sensor'],
      fallback: _toBool(
        z['allowGasThresholdEdit'] ??
            z['allow_gas_threshold_edit'] ??
            z['canEditGasThreshold'] ??
            z['can_edit_gas_threshold'],
        fallback: true,
      ),
    );
    final useLightSensor = enabledSensors.contains('light')
        ? true
        : _toBool(
      z['useLightSensor'] ??
          z['use_light'] ??
          z['useLight'] ??
          z['use_light_sensor'] ??
          z['hasLightSensor'] ??
          z['has_light_sensor'],
      fallback: _toBool(
        z['allowLightThresholdEdit'] ??
            z['allow_light_threshold_edit'] ??
            z['canEditLightThreshold'] ??
            z['can_edit_light_threshold'],
        fallback: true,
      ),
    );
    final useTemperatureSensor = enabledSensors.contains('temperature')
        ? true
        : _toBool(
      z['useTemperatureSensor'] ??
          z['use_temp'] ??
          z['useTemp'] ??
          z['use_temperature_sensor'] ??
          z['hasTemperatureSensor'] ??
          z['has_temperature_sensor'],
      fallback: _toBool(
        z['allowTemperatureThresholdEdit'] ??
            z['allow_temperature_threshold_edit'] ??
            z['canEditTemperatureThreshold'] ??
            z['can_edit_temperature_threshold'],
        fallback: true,
      ),
    );

    final normalized = {
      ...z,
      'id': id,
      'name': displayName,
      // Keep explicit sensor flags in normalized data so UI stays in sync
      // even when backend sends only enabledSensors or mixed key formats.
      'useHumiditySensor': useHumiditySensor,
      'useGasSensor': useGasSensor,
      'useLightSensor': useLightSensor,
      'useTemperatureSensor': useTemperatureSensor,
      'use_hum': useHumiditySensor,
      'use_temp': useTemperatureSensor,
      'use_gaz': useGasSensor,
      'use_light': useLightSensor,
      'humidity': _toDouble(z['humidity']),
      'nutrition': _toDouble(z['nutrition'] ?? z['gaz'] ?? z['gas'] ?? z['n']),
      'gaz': _toDouble(z['gaz'] ?? z['nutrition'] ?? z['gas'] ?? z['n']),
      'light': _toDouble(z['light']),
      'temperature': _toDouble(z['temperature'] ?? z['temp']),
      'thresholdHumidity': _toDouble(z['thresholdHumidity'], fallback: 30),
      'thresholdNutrition': _toDouble(z['thresholdNutrition'] ?? z['thresholdgaz'] ?? z['thresholdGaz'], fallback: 50),
      'thresholdgaz': _toDouble(z['thresholdgaz'] ?? z['thresholdGaz'] ?? z['thresholdNutrition'], fallback: 50),
      'thresholdGaz': _toDouble(z['thresholdGaz'] ?? z['thresholdgaz'] ?? z['thresholdNutrition'], fallback: 50),
      'thresholdLight': _toDouble(z['thresholdLight'], fallback: 200),
      'thresholdTemperature': _toDouble(
        z['thresholdTemperature'] ?? z['thresholdTemp'] ?? z['threshold_temperature'],
        fallback: 25,
      ),
      'allowValveControl': _toBool(
        z['allowValveControl'] ?? z['canControlValve'] ?? z['allow_ev_control'] ?? z['use_ev'] ?? z['useEv'],
        fallback: true,
      ),
      'allowThresholdEdit': _toBool(
        z['allowThresholdEdit'] ?? z['canEditThresholds'] ?? z['allow_threshold_edit'],
        fallback: true,
      ),
      'allowHumidityThresholdEdit': _toBool(
        z['allowHumidityThresholdEdit'] ??
            z['allow_humidity_threshold_edit'] ??
            z['canEditHumidityThreshold'] ??
            z['can_edit_humidity_threshold'],
        fallback: useHumiditySensor,
      ),
      'allowGasThresholdEdit': _toBool(
        z['allowGasThresholdEdit'] ??
            z['allow_gas_threshold_edit'] ??
            z['canEditGasThreshold'] ??
            z['can_edit_gas_threshold'],
        fallback: useGasSensor,
      ),
      'allowLightThresholdEdit': _toBool(
        z['allowLightThresholdEdit'] ??
            z['allow_light_threshold_edit'] ??
            z['canEditLightThreshold'] ??
            z['can_edit_light_threshold'],
        fallback: useLightSensor,
      ),
      'allowTemperatureThresholdEdit': _toBool(
        z['allowTemperatureThresholdEdit'] ??
            z['allow_temperature_threshold_edit'] ??
            z['canEditTemperatureThreshold'] ??
            z['can_edit_temperature_threshold'],
        fallback: useTemperatureSensor,
      ),
      'valve': z['valve'] ??
          z['valve_on'] ??
          z['valveOn'] ??
          z['ev'] ??
          z['ev_state'] ??
          z['state'] ??
          z['relay'] ??
          z['pump'],
      'ev_mode': _isManualMode(z['ev_mode'] ?? z['evMode']) ? 'MANUAL' : 'AUTO',
      'latest_alert_message': (z['latest_alert_message'] ?? '').toString(),
      'latest_alert_level':
      (z['latest_alert_level'] ?? 'WARNING').toString().toUpperCase(),
      'latest_alert_created_at': (z['latest_alert_created_at'] ?? '').toString(),
    };
    normalized['use_ev'] = _toBool(normalized['allowValveControl']);

    if (applyLocalOverrides) {
      final idOverrides = _thresholdPermissionOverridesByZoneId[id];
      if (idOverrides != null) {
        normalized.addAll(idOverrides);
      }

      final zoneNameKey = (normalized['name'] ?? '').toString().trim().toLowerCase();
      if (zoneNameKey.isNotEmpty &&
          _pendingThresholdPermissionsByZoneName.containsKey(zoneNameKey)) {
        final pending = _pendingThresholdPermissionsByZoneName.remove(zoneNameKey)!;
        normalized.addAll(pending);
        _thresholdPermissionOverridesByZoneId[id] = pending;
        // Non-blocking save to avoid slowing UI normalization path.
        _saveZoneOverridesLocally();
      }
    }

    return normalized;
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  double _toDouble(dynamic v, {double fallback = 0}) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? fallback;
  }

  bool _toBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final text = (v ?? '').toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'oui') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'non') {
      return false;
    }
    return fallback;
  }

  bool _isManualMode(dynamic mode) {
    if (mode is bool) return mode;
    if (mode is num) return mode != 0;
    final v = (mode ?? '').toString().trim().toUpperCase();
    return v == 'MANUAL' ||
        v == 'MANUEL' ||
        v == 'ON' ||
        v == 'TRUE' ||
        v == '1';
  }

  bool _isValveOn(dynamic valve) {
    final v = (valve ?? '').toString().trim().toLowerCase();
    return valve == true ||
        valve == 1 ||
        v == '1' ||
        v == 'true' ||
        v == 'on' ||
        v == 'marche';
  }

  String zoneLabel(Map<String, dynamic> zone) {
    final name = (zone['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    return 'Zone ${_toInt(zone['id'])}';
  }

  bool _canControlValve(Map<String, dynamic> zone) {
    return _toBool(
      zone['allowValveControl'] ?? zone['use_ev'] ?? zone['useEv'],
      fallback: true,
    );
  }

  bool _canEditHumidityThreshold(Map<String, dynamic> zone) {
    return _usesHumiditySensor(zone) &&
        _toBool(
          zone['allowHumidityThresholdEdit'],
          fallback: _toBool(zone['allowThresholdEdit'], fallback: true),
        );
  }

  bool _canEditGasThreshold(Map<String, dynamic> zone) {
    return _usesGasSensor(zone) &&
        _toBool(
          zone['allowGasThresholdEdit'],
          fallback: _toBool(zone['allowThresholdEdit'], fallback: true),
        );
  }

  bool _canEditLightThreshold(Map<String, dynamic> zone) {
    return _usesLightSensor(zone) &&
        _toBool(
          zone['allowLightThresholdEdit'],
          fallback: _toBool(zone['allowThresholdEdit'], fallback: true),
        );
  }

  bool _canEditTemperatureThreshold(Map<String, dynamic> zone) {
    return _usesTemperatureSensor(zone) &&
        _toBool(
          zone['allowTemperatureThresholdEdit'],
          fallback: _toBool(zone['allowThresholdEdit'], fallback: true),
        );
  }

  bool _canEditAnyThreshold(Map<String, dynamic> zone) {
    return _canEditHumidityThreshold(zone) ||
        _canEditGasThreshold(zone) ||
        _canEditLightThreshold(zone) ||
        _canEditTemperatureThreshold(zone);
  }

  bool _usesHumiditySensor(Map<String, dynamic> zone) {
    return _toBool(zone['useHumiditySensor'] ?? zone['use_hum'] ?? zone['useHum'], fallback: true);
  }

  bool _usesGasSensor(Map<String, dynamic> zone) {
    return _toBool(zone['useGasSensor'] ?? zone['use_gaz'] ?? zone['useGaz'], fallback: true);
  }

  bool _usesLightSensor(Map<String, dynamic> zone) {
    return _toBool(zone['useLightSensor'] ?? zone['use_light'] ?? zone['useLight'], fallback: true);
  }

  bool _usesTemperatureSensor(Map<String, dynamic> zone) {
    return _toBool(zone['useTemperatureSensor'] ?? zone['use_temp'] ?? zone['useTemp'], fallback: true);
  }

  bool _zoneSensorsMatch(
      Map<String, dynamic> zone, {
        required bool useValveControl,
        required bool useHumiditySensor,
        required bool useGasSensor,
        required bool useLightSensor,
        required bool useTemperatureSensor,
      }) {
    return _canControlValve(zone) == useValveControl &&
        _usesHumiditySensor(zone) == useHumiditySensor &&
        _usesGasSensor(zone) == useGasSensor &&
        _usesLightSensor(zone) == useLightSensor &&
        _usesTemperatureSensor(zone) == useTemperatureSensor;
  }

  Color getColor(double value, double threshold) {
    if (value < threshold) return Colors.red;
    if (value < threshold + 5) return Colors.orange;
    return Colors.green;
  }

  String _modeLabel(dynamic mode) =>
      _isManualMode(mode) ? _tr('MANUEL', 'MANUAL') : 'AUTO';

  int _landscapePageCount() {
    if (zones.isEmpty) return 1;
    return ((zones.length - 1) ~/ 4) + 1;
  }

  void _clampLandscapePage() {
    final maxPage = _landscapePageCount() - 1;
    if (currentLandscapePage > maxPage) currentLandscapePage = maxPage;
    if (currentLandscapePage < 0) currentLandscapePage = 0;
  }

  List<Map<String, dynamic>> _visibleLandscapeZones() {
    _clampLandscapePage();
    if (zones.isEmpty) return const [];

    final start = currentLandscapePage * 4;
    if (start >= zones.length) return const [];
    final end = (start + 4) > zones.length ? zones.length : start + 4;
    return zones.sublist(start, end);
  }

  bool _handleLandscapeZoneScrollNotification(
      ScrollNotification notification,
      int zoneGlobalIndex,
      ) {
    if (zones.isEmpty || zoneGlobalIndex < 0 || zoneGlobalIndex >= zones.length) {
      return false;
    }

    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || metrics.maxScrollExtent <= 0) {
      return false;
    }

    final reachedBottom = metrics.pixels >= (metrics.maxScrollExtent - 2);
    if (!reachedBottom) return false;

    final shouldAdvance = notification is ScrollEndNotification ||
        (notification is OverscrollNotification && notification.overscroll > 0);
    if (!shouldAdvance) return false;

    final nextIndex = zoneGlobalIndex + 1;
    if (nextIndex >= zones.length) return false;

    final now = DateTime.now();
    if (_lastLandscapeAutoAdvanceAt != null &&
        now.difference(_lastLandscapeAutoAdvanceAt!) <
            const Duration(milliseconds: 320)) {
      return false;
    }
    _lastLandscapeAutoAdvanceAt = now;

    setState(() {
      currentZoneIndex = nextIndex;
      selectedZoneId = _toInt(zones[nextIndex]['id']);
      currentLandscapePage = nextIndex ~/ 4;
    });

    return false;
  }

  bool _handleZoneCardScrollNotification(ScrollNotification notification) {
    if (!_mainScrollController.hasClients) return false;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;

    double forwardDelta = 0;

    if (notification is OverscrollNotification) {
      if (notification.dragDetails == null) return false;
      if (notification.overscroll.abs() < 1.5) return false;
      forwardDelta = notification.overscroll;
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() < 2.0) return false;
      final atBottom = metrics.pixels >= (metrics.maxScrollExtent - 1);
      final atTop = metrics.pixels <= (metrics.minScrollExtent + 1);
      if ((delta > 0 && atBottom) || (delta < 0 && atTop)) {
        forwardDelta = delta;
      }
    }

    if (forwardDelta == 0) return false;

    final mainPosition = _mainScrollController.position;
    final target = (mainPosition.pixels + forwardDelta)
        .clamp(mainPosition.minScrollExtent, mainPosition.maxScrollExtent)
        .toDouble();

    if ((target - mainPosition.pixels).abs() < 0.5) return false;
    _mainScrollController.jumpTo(target);
    return false;
  }

  Future<void> _setZoneMode(Map<String, dynamic> zone, bool isManual) async {
    _markLocalUiAction();
    final zoneId = _toInt(zone['id'], fallback: -1);
    if (zoneId <= 0) return;

    final previousMode = zone['ev_mode'];
    final nextMode = isManual ? 'MANUAL' : 'AUTO';

    setState(() {
      zone['ev_mode'] = nextMode;
    });

    final response = await _authorizedPost(
      '/command',
      body: {
        'id': zoneId,
        'zone_id': zoneId,
        'zoneId': zoneId,
        'ev_mode': nextMode,
        'evMode': nextMode,
        'mode': nextMode,
        'manual': isManual,
        'is_manual': isManual,
      },
    );

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      // Fallback: if dedicated endpoint is unavailable, push mode through sync payload.
      final synced = await _syncZoneConfig();
      if (!mounted) return;

      if (synced) {
        final refreshed = zones.where((z) => _toInt(z['id']) == zoneId).toList();
        final backendApplied =
            refreshed.isNotEmpty && _isManualMode(refreshed.first['ev_mode']) == isManual;
        if (backendApplied) return;
      }

      setState(() {
        zone['ev_mode'] = previousMode;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec mise a jour mode electrovanne', 'Failed to update valve mode'))),
      );
      return;
    }
    // Keep UI stable: rely on realtime socket update instead of forcing a full refresh.
  }

  Future<void> _toggleValveManual(Map<String, dynamic> zone) async {
    _markLocalUiAction();
    if (!_isManualMode(zone['ev_mode'])) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Passez en mode MANUEL pour commander la vanne', 'Switch to MANUAL mode to control the valve'))),
      );
      return;
    }

    final zoneId = _toInt(zone['id'], fallback: -1);
    if (zoneId <= 0) return;

    final previousValve = zone['valve'];
    final nextValveOn = !_isValveOn(previousValve);

    setState(() {
      zone['valve'] = nextValveOn;
    });

    final response = await _authorizedPost(
      '/command',
      body: {
        'id': zoneId,
        'zone': zoneId,
        'zone_id': zoneId,
        'zoneId': zoneId,
        'mode': 'MANUAL',
        'ev_state': nextValveOn,
        'evState': nextValveOn,
        'valve': nextValveOn ? 1 : 0,
        'valve_on': nextValveOn,
        'isOpen': nextValveOn,
        'state': nextValveOn ? 'ON' : 'OFF',
        'command': nextValveOn ? 'ON' : 'OFF',
        'ev': nextValveOn,
      },
    );

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      setState(() {
        zone['valve'] = previousValve;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec commande electrovanne', 'Failed to send valve command'))),
      );
    }
    // On success, keep optimistic UI and let realtime socket reconcile state.
  }

  Widget _buildValveLamp(dynamic valve) {
    final isOn = _isValveOn(valve);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isOn ? Colors.green : Colors.red,
        border: Border.all(color: Colors.black26),
        boxShadow: [
          BoxShadow(
            color: (isOn ? Colors.green : Colors.red).withOpacity(0.4),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  Widget _buildZoneAlertBox(Map<String, dynamic> zone) {
    final zoneId = _toInt(zone['id'], fallback: -1);
    final alert = _resolveLatestAlert(zoneId, zone);
    if (alert == null) return const SizedBox.shrink();

    final message = alert['message']!;
    final level = alert['level']!;

    final isError = level == 'ERROR' || level == 'CRITICAL';
    final borderColor = isError ? Colors.red : Colors.orange;
    final bgColor = isError ? Colors.red.shade50 : Colors.orange.shade50;
    final textColor = isError ? Colors.red.shade800 : Colors.orange.shade800;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: borderColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              softWrap: true,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeAlertInline(Map<String, dynamic> zone) {
    final zoneId = _toInt(zone['id'], fallback: -1);
    final alert = _resolveLatestAlert(zoneId, zone);
    if (alert == null) return const SizedBox.shrink();

    final message = alert['message']!;
    final level = alert['level']!;
    final isError = level == 'ERROR' || level == 'CRITICAL';
    final borderColor = isError ? Colors.red : Colors.orange;
    final bgColor = isError ? Colors.red.shade50 : Colors.orange.shade50;
    final textColor = isError ? Colors.red.shade800 : Colors.orange.shade800;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: borderColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              softWrap: true,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, String>> _collectActiveZoneAlerts() {
    final alerts = <Map<String, String>>[];

    for (final zone in zones) {
      final zoneId = _toInt(zone['id'], fallback: -1);
      if (zoneId <= 0) continue;

      final alert = _resolveLatestAlert(zoneId, zone);
      if (alert == null) continue;

      alerts.add({
        'zoneLabel': zoneLabel(zone),
        'message': alert['message'] ?? '',
        'level': alert['level'] ?? 'WARNING',
      });
    }

    return alerts;
  }

  Widget _buildGlobalAlertsCard(List<Map<String, String>> alerts) {
    final hasAlerts = alerts.isNotEmpty;

    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.orange.shade200, width: 1.6),
      ),
      elevation: 7,
      shadowColor: Colors.orange.withOpacity(0.2),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.orange.shade50, Colors.red.shade50],
          ),
        ),
        child: SizedBox(
          height: 180,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(
                      _tr('Alertes des zones', 'Zone alerts'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: hasAlerts
                      ? ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: alerts.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final entry = alerts[index];
                            final level = (entry['level'] ?? 'WARNING').toUpperCase();
                            final isError = level == 'ERROR' || level == 'CRITICAL';
                            final borderColor =
                                isError ? Colors.red.shade300 : Colors.orange.shade300;
                            final bgColor =
                                isError ? Colors.red.shade50 : Colors.orange.shade50;
                            final textColor =
                                isError ? Colors.red.shade800 : Colors.orange.shade800;

                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: bgColor,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: borderColor),
                              ),
                              child: RichText(
                                text: TextSpan(
                                  style: TextStyle(color: textColor, fontSize: 13),
                                  children: [
                                    TextSpan(
                                      text: '${entry['zoneLabel']} : ',
                                      style: const TextStyle(fontWeight: FontWeight.w700),
                                    ),
                                    TextSpan(
                                      text: entry['message'] ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                ),
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        )
                      : Center(
                          child: Text(
                            _tr('Aucune alerte active', 'No active alert'),
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatPlanNumber(dynamic value, {int decimals = 2}) {
    final parsed = _toDouble(value, fallback: double.nan);
    if (parsed.isNaN || parsed.isInfinite) return '--';
    return parsed.toStringAsFixed(decimals);
  }

  double? _toPositiveDoubleOrNull(dynamic value) {
    if (value == null) return null;
    final parsed = _toDouble(value, fallback: double.nan);
    if (parsed.isNaN || parsed.isInfinite || parsed <= 0) return null;
    return parsed;
  }

  Widget _buildPlanMetricRow({
    required String frLabel,
    required String enLabel,
    required String frValue,
    required String enValue,
    Color? valueColor,
    FontWeight valueWeight = FontWeight.w600,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              _tr(frLabel, enLabel),
              style: TextStyle(color: Colors.grey.shade800),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _tr(frValue, enValue),
            style: TextStyle(
              color: valueColor ?? Colors.black87,
              fontWeight: valueWeight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDosagePlanCard(Map<String, dynamic> plan) {
    final productsRaw = plan['products'];
    final products = productsRaw is Map
        ? Map<String, dynamic>.from(productsRaw)
        : <String, dynamic>{};
    final totalsRaw = plan['totals'];
    final totals = totalsRaw is Map
        ? Map<String, dynamic>.from(totalsRaw)
        : <String, dynamic>{};

    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.teal.shade200, width: 1.6),
      ),
      elevation: 7,
      shadowColor: Colors.teal.withOpacity(0.2),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calculate_outlined, color: Colors.teal.shade600),
                const SizedBox(width: 8),
                Text(
                  _tr('Plan de dosage calcule', 'Calculated dosing plan'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildPlanMetricRow(
              frLabel: 'Niveau d eau',
              enLabel: 'Water level',
              frValue: '${_formatPlanNumber(plan['water_level_percent'])} %',
              enValue: '${_formatPlanNumber(plan['water_level_percent'])} %',
            ),
            _buildPlanMetricRow(
              frLabel: 'Capacite citerne',
              enLabel: 'Tank capacity',
              frValue: '${_formatPlanNumber(plan['tank_capacity_liters'])} L',
              enValue: '${_formatPlanNumber(plan['tank_capacity_liters'])} L',
            ),
            _buildPlanMetricRow(
              frLabel: 'Eau estimee',
              enLabel: 'Estimated water',
              frValue: '${_formatPlanNumber(plan['water_liters'])} L',
              enValue: '${_formatPlanNumber(plan['water_liters'])} L',
            ),
            const SizedBox(height: 10),
            for (final product in const ['A', 'B', 'C'])
              if (products[product] is Map)
                Builder(
                  builder: (_) {
                    final productMap = Map<String, dynamic>.from(
                      products[product] as Map,
                    );
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.teal.shade100),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tr('Produit $product', 'Product $product'),
                            style: TextStyle(
                              color: Colors.teal.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _buildPlanMetricRow(
                            frLabel: 'Dose theorique',
                            enLabel: 'Theoretical dose',
                            frValue:
                                '${_formatPlanNumber(productMap['theoretical_dose_ml'])} mL',
                            enValue:
                                '${_formatPlanNumber(productMap['theoretical_dose_ml'])} mL',
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Dose min absolue',
                            enLabel: 'Min absolute dose',
                            frValue:
                                '${_formatPlanNumber(productMap['min_dose_ml_abs'])} mL',
                            enValue:
                                '${_formatPlanNumber(productMap['min_dose_ml_abs'])} mL',
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Dose max absolue',
                            enLabel: 'Max absolute dose',
                            frValue:
                                '${_formatPlanNumber(productMap['max_dose_ml_abs'])} mL',
                            enValue:
                                '${_formatPlanNumber(productMap['max_dose_ml_abs'])} mL',
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Dose cible',
                            enLabel: 'Target dose',
                            frValue:
                                '${_formatPlanNumber(productMap['target_dose_ml'])} mL',
                            enValue:
                                '${_formatPlanNumber(productMap['target_dose_ml'])} mL',
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Course',
                            enLabel: 'Course',
                            frValue: '${_formatPlanNumber(productMap['course_mm'])} mm',
                            enValue: '${_formatPlanNumber(productMap['course_mm'])} mm',
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Tours',
                            enLabel: 'Turns',
                            frValue: _formatPlanNumber(productMap['turns']),
                            enValue: _formatPlanNumber(productMap['turns']),
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Pas flottants',
                            enLabel: 'Floating steps',
                            frValue: _formatPlanNumber(productMap['steps_float']),
                            enValue: _formatPlanNumber(productMap['steps_float']),
                          ),
                          _buildPlanMetricRow(
                            frLabel: 'Pas commandes',
                            enLabel: 'Commanded steps',
                            frValue: '${_toInt(productMap['steps'])} pas',
                            enValue: '${_toInt(productMap['steps'])} steps',
                          ),
                        ],
                      ),
                    );
                  },
                ),
            _buildPlanMetricRow(
              frLabel: 'Total dose',
              enLabel: 'Total dose',
              frValue: '${_formatPlanNumber(totals['target_dose_ml'])} mL',
              enValue: '${_formatPlanNumber(totals['target_dose_ml'])} mL',
              valueColor: Colors.teal.shade700,
              valueWeight: FontWeight.bold,
            ),
            _buildPlanMetricRow(
              frLabel: 'Total pas',
              enLabel: 'Total steps',
              frValue: '${_toInt(totals['steps'])} pas',
              enValue: '${_toInt(totals['steps'])} steps',
              valueColor: Colors.teal.shade700,
              valueWeight: FontWeight.bold,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> addZone() async {
    final payload = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => _ZoneCommandSelectionScreen(
          isEnglish: _isEnglish,
        ),
      ),
    );

    if (payload == null) return;

    final zoneName = (payload['name'] ?? '').toString().trim();
    if (zoneName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Veuillez saisir le nom de la zone', 'Please enter the zone name'))),
      );
      return;
    }
    if (_isZoneNameAlreadyUsed(zoneName)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('nom deja existe', 'name already exists'))),
      );
      return;
    }

    final useValveControl = _toBool(payload['useValveControl'], fallback: true);
    final useHumiditySensor = _toBool(payload['useHumiditySensor'], fallback: true);
    final useGasSensor = _toBool(payload['useGasSensor'], fallback: true);
    final useLightSensor = _toBool(payload['useLightSensor'], fallback: true);
    final useTemperatureSensor =
    _toBool(payload['useTemperatureSensor'], fallback: true);

    final allowHumidityThresholdEdit = useHumiditySensor;
    final allowGasThresholdEdit = useGasSensor;
    final allowLightThresholdEdit = useLightSensor;
    final allowTemperatureThresholdEdit = useTemperatureSensor;

    final zonePermissionOverrides = <String, bool>{
      'allowValveControl': useValveControl,
      'useHumiditySensor': useHumiditySensor,
      'useGasSensor': useGasSensor,
      'useLightSensor': useLightSensor,
      'useTemperatureSensor': useTemperatureSensor,
      'allowHumidityThresholdEdit': allowHumidityThresholdEdit,
      'allowGasThresholdEdit': allowGasThresholdEdit,
      'allowLightThresholdEdit': allowLightThresholdEdit,
      'allowTemperatureThresholdEdit': allowTemperatureThresholdEdit,
    };

    final response = await _authorizedPost(
      '/add-zone',
      body: {
        'name': zoneName,
        'allowValveControl': useValveControl,
        'allow_ev_control': useValveControl,
        'canControlValve': useValveControl,
        'enabledSensors': [
          if (useHumiditySensor) 'humidity',
          if (useGasSensor) 'gas',
          if (useLightSensor) 'light',
          if (useTemperatureSensor) 'temperature',
        ],
        'useHumiditySensor': useHumiditySensor,
        'useGasSensor': useGasSensor,
        'useLightSensor': useLightSensor,
        'useTemperatureSensor': useTemperatureSensor,
        'use_humidity_sensor': useHumiditySensor,
        'use_gas_sensor': useGasSensor,
        'use_light_sensor': useLightSensor,
        'use_temperature_sensor': useTemperatureSensor,
        'allowHumidityThresholdEdit': allowHumidityThresholdEdit,
        'allowGasThresholdEdit': allowGasThresholdEdit,
        'allowLightThresholdEdit': allowLightThresholdEdit,
        'allowTemperatureThresholdEdit': allowTemperatureThresholdEdit,
        'allow_humidity_threshold_edit': allowHumidityThresholdEdit,
        'allow_gas_threshold_edit': allowGasThresholdEdit,
        'allow_light_threshold_edit': allowLightThresholdEdit,
        'allow_temperature_threshold_edit': allowTemperatureThresholdEdit,
        'canEditHumidityThreshold': allowHumidityThresholdEdit,
        'canEditGasThreshold': allowGasThresholdEdit,
        'canEditLightThreshold': allowLightThresholdEdit,
        'canEditTemperatureThreshold': allowTemperatureThresholdEdit,
        'allowThresholdEdit': allowHumidityThresholdEdit ||
            allowGasThresholdEdit ||
            allowLightThresholdEdit ||
            allowTemperatureThresholdEdit,
      },
    );

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      final serverMessage = response?.statusCode == 409
          ? _tr('nom deja existe', 'name already exists')
          : _extractApiErrorMessage(response);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(serverMessage ?? _tr('Echec ajout zone', 'Failed to add zone'))),
      );
      return;
    }

    setState(() {
      _pendingThresholdPermissionsByZoneName[zoneName.toLowerCase()] =
          zonePermissionOverrides;
    });
    await _saveZoneOverridesLocally();

    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map) {
        final createdId = _toInt(
          parsed['id'] ?? parsed['zone_id'] ?? parsed['zoneId'],
          fallback: -1,
        );
        if (createdId > 0) {
          setState(() {
            _thresholdPermissionOverridesByZoneId[createdId] =
                zonePermissionOverrides;
          });
          await _saveZoneOverridesLocally();
        }
      }
    } catch (_) {}

    await _fetchDashboardSnapshot();
    await _fetchZoneConfig();
  }

  Future<void> removeZone() async {
    if (selectedZoneId == null) return;
    final removedZoneId = selectedZoneId;

    final response = await _authorizedPost(
      '/remove-zone',
      body: {'id': selectedZoneId},
    );

    if (response == null || response.statusCode >= 400) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec suppression zone', 'Failed to remove zone'))),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      if (removedZoneId != null) {
        _thresholdPermissionOverridesByZoneId.remove(removedZoneId);
      }
    });
    await _saveZoneOverridesLocally();
    await _fetchDashboardSnapshot();
    await _fetchZoneConfig();
  }

  Future<void> _confirmAndRemoveZone() async {
    if (selectedZoneId == null) return;

    Map<String, dynamic>? selectedZone;
    for (final zone in zones) {
      if (_toInt(zone['id']) == selectedZoneId) {
        selectedZone = zone;
        break;
      }
    }

    final zoneName = selectedZone != null
        ? zoneLabel(selectedZone)
        : 'Zone $selectedZoneId';

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr('Confirmer la suppression', 'Confirm deletion')),
        content: Text(_tr('Voulez-vous vraiment supprimer $zoneName ?', 'Do you really want to delete $zoneName?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_tr('Annuler', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600),
            child: Text(_tr('Supprimer', 'Delete')),
          ),
        ],
      ),
    ) ??
        false;

    if (!shouldDelete) return;
    await removeZone();
  }

  Future<void> showEditDialog(Map<String, dynamic> zone) async {
    final canEditHumidity = _canEditHumidityThreshold(zone);
    final canEditGas = _canEditGasThreshold(zone);
    final canEditLight = _canEditLightThreshold(zone);
    final canEditTemperature = _canEditTemperatureThreshold(zone);

    if (!(canEditHumidity || canEditGas || canEditLight || canEditTemperature)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Aucun capteur actif modifiable pour cette zone', 'No editable active sensor for this zone'))),
      );
      return;
    }

    String humidityText = _toDouble(zone['thresholdHumidity']).toString();
    String nutritionText = _toDouble(zone['thresholdNutrition'] ?? zone['thresholdgaz'] ?? zone['thresholdGaz']).toString();
    String lightText = _toDouble(zone['thresholdLight']).toString();
    String temperatureText = _toDouble(zone['thresholdTemperature']).toString();

    final payload = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr('Modifier Seuils ${zoneLabel(zone)}', 'Edit thresholds ${zoneLabel(zone)}')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_usesHumiditySensor(zone))
                TextFormField(
                  initialValue: humidityText,
                  onChanged: (value) => humidityText = value,
                  keyboardType: TextInputType.number,
                  enabled: canEditHumidity,
                  decoration: InputDecoration(labelText: _tr('Seuil Humidite', 'Humidity threshold')),
                ),
              if (_usesGasSensor(zone))
                TextFormField(
                  initialValue: nutritionText,
                  onChanged: (value) => nutritionText = value,
                  keyboardType: TextInputType.number,
                  enabled: canEditGas,
                  decoration: InputDecoration(labelText: _tr('Seuil Gaz (ppm)', 'Gas threshold (ppm)')),
                ),
              if (_usesLightSensor(zone))
                TextFormField(
                  initialValue: lightText,
                  onChanged: (value) => lightText = value,
                  keyboardType: TextInputType.number,
                  enabled: canEditLight,
                  decoration: InputDecoration(labelText: _tr('Seuil Lumiere', 'Light threshold')),
                ),
              if (_usesTemperatureSensor(zone))
                TextFormField(
                  initialValue: temperatureText,
                  onChanged: (value) => temperatureText = value,
                  keyboardType: TextInputType.number,
                  enabled: canEditTemperature,
                  decoration: InputDecoration(labelText: _tr('Seuil Temperature (°C)', 'Temperature threshold (°C)')),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext, null);
            },
            child: Text(_tr('Annuler', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              final nextPayload = <String, dynamic>{
                'id': _toInt(zone['id']),
              };

              if (canEditHumidity) {
                nextPayload['thresholdHumidity'] =
                    double.tryParse(humidityText.trim()) ??
                        _toDouble(zone['thresholdHumidity'], fallback: 30);
              }

              if (canEditGas) {
                final gazValue = double.tryParse(nutritionText.trim()) ??
                    _toDouble(zone['thresholdNutrition'], fallback: 50);
                nextPayload['thresholdNutrition'] = gazValue;
                nextPayload['thresholdgaz'] = gazValue;
                nextPayload['thresholdGaz'] = gazValue;
              }

              if (canEditLight) {
                nextPayload['thresholdLight'] =
                    double.tryParse(lightText.trim()) ??
                        _toDouble(zone['thresholdLight'], fallback: 200);
              }

              if (canEditTemperature) {
                nextPayload['thresholdTemperature'] =
                    double.tryParse(temperatureText.trim()) ??
                        _toDouble(zone['thresholdTemperature'], fallback: 25);
              }

              Navigator.pop(dialogContext, nextPayload);
            },
            child: Text(_tr('Sauvegarder', 'Save')),
          ),
        ],
      ),
    );

    if (payload == null) return;
    _markLocalUiAction();

    final response = await _authorizedPost('/update-thresholds', body: payload);

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Echec mise a jour seuils', 'Failed to update thresholds'))),
      );
      return;
    }

    // Apply immediate local update so user sees changes without waiting socket.
    setState(() {
      if (payload.containsKey('thresholdHumidity')) {
        zone['thresholdHumidity'] = _toDouble(payload['thresholdHumidity']);
      }
      if (payload.containsKey('thresholdNutrition')) {
        zone['thresholdNutrition'] = _toDouble(payload['thresholdNutrition']);
        zone['thresholdgaz'] = _toDouble(payload['thresholdNutrition']);
        zone['thresholdGaz'] = _toDouble(payload['thresholdNutrition']);
      }
      if (payload.containsKey('thresholdLight')) {
        zone['thresholdLight'] = _toDouble(payload['thresholdLight']);
      }
      if (payload.containsKey('thresholdTemperature')) {
        zone['thresholdTemperature'] = _toDouble(payload['thresholdTemperature']);
      }
    });

    await _fetchZoneConfig();
  }

  Future<void> showEditNameDialog(Map<String, dynamic> zone) async {
    String zoneName = (zone['name'] ?? '').toString();

    final payload = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr('Modifier Nom ${zoneLabel(zone)}', 'Edit name ${zoneLabel(zone)}')),
        content: TextFormField(
          initialValue: zoneName,
          onChanged: (value) => zoneName = value,
          decoration: InputDecoration(labelText: _tr('Nom de la culture', 'Crop name')),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext, null);
            },
            child: Text(_tr('Annuler', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext, {
                'id': _toInt(zone['id']),
                'name': zoneName.trim(),
              });
            },
            child: Text(_tr('Sauvegarder', 'Save')),
          ),
        ],
      ),
    );

    if (payload == null) return;
    final zoneId = _toInt(payload['id'], fallback: -1);
    final newZoneName = (payload['name'] ?? '').toString().trim();
    if (zoneId <= 0 || newZoneName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Nom de zone invalide', 'Invalid zone name'))),
      );
      return;
    }
    if (_isZoneNameAlreadyUsed(newZoneName, excludeZoneId: zoneId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('nom deja existe', 'name already exists'))),
      );
      return;
    }

    _markLocalUiAction();

    final response = await _authorizedPost('/update-zone-name', body: {
      'id': zoneId,
      'name': newZoneName,
    });

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      final serverMessage = response?.statusCode == 409
          ? _tr('nom deja existe', 'name already exists')
          : _extractApiErrorMessage(response);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(serverMessage ?? _tr('Echec mise a jour nom', 'Failed to update name'))),
      );
      return;
    }

    // Keep UI name updated immediately after successful save.
    if (zoneId > 0 && newZoneName.isNotEmpty) {
      _pinZoneName(zoneId, newZoneName);
    }

    setState(() {
      zone['name'] = newZoneName;
    });

    await _syncZoneConfig();
  }

  Future<void> showEditSensorsDialog(Map<String, dynamic> zone) async {
    final zoneId = _toInt(zone['id'], fallback: -1);
    if (zoneId <= 0) return;

    final previousOverrides = _thresholdPermissionOverridesByZoneId[zoneId] == null
        ? null
        : Map<String, bool>.from(_thresholdPermissionOverridesByZoneId[zoneId]!);
    final previousZoneValues = <String, dynamic>{
      'allowValveControl': zone['allowValveControl'],
      'useHumiditySensor': zone['useHumiditySensor'],
      'useGasSensor': zone['useGasSensor'],
      'useLightSensor': zone['useLightSensor'],
      'useTemperatureSensor': zone['useTemperatureSensor'],
      'use_ev': zone['use_ev'],
      'use_hum': zone['use_hum'],
      'use_gaz': zone['use_gaz'],
      'use_light': zone['use_light'],
      'use_temp': zone['use_temp'],
      'allowHumidityThresholdEdit': zone['allowHumidityThresholdEdit'],
      'allowGasThresholdEdit': zone['allowGasThresholdEdit'],
      'allowLightThresholdEdit': zone['allowLightThresholdEdit'],
      'allowTemperatureThresholdEdit': zone['allowTemperatureThresholdEdit'],
      'allowThresholdEdit': zone['allowThresholdEdit'],
    };

    final payload = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => _ZoneCommandSelectionScreen(
          isEditMode: true,
          isEnglish: _isEnglish,
          initialName: zoneLabel(zone),
          initialUseValveControl: _canControlValve(zone),
          initialUseHumiditySensor: _usesHumiditySensor(zone),
          initialUseGasSensor: _usesGasSensor(zone),
          initialUseLightSensor: _usesLightSensor(zone),
          initialUseTemperatureSensor: _usesTemperatureSensor(zone),
        ),
      ),
    );

    if (payload == null) return;
    _markLocalUiAction();

    final useValveControl = _toBool(payload['useValveControl'], fallback: true);
    final useHumiditySensor = _toBool(payload['useHumiditySensor'], fallback: true);
    final useGasSensor = _toBool(payload['useGasSensor'], fallback: true);
    final useLightSensor = _toBool(payload['useLightSensor'], fallback: true);
    final useTemperatureSensor =
    _toBool(payload['useTemperatureSensor'], fallback: true);

    final zonePermissionOverrides = <String, bool>{
      'allowValveControl': useValveControl,
      'useHumiditySensor': useHumiditySensor,
      'useGasSensor': useGasSensor,
      'useLightSensor': useLightSensor,
      'useTemperatureSensor': useTemperatureSensor,
      'use_ev': useValveControl,
      'use_hum': useHumiditySensor,
      'use_gaz': useGasSensor,
      'use_light': useLightSensor,
      'use_temp': useTemperatureSensor,
      'allowHumidityThresholdEdit': useHumiditySensor,
      'allowGasThresholdEdit': useGasSensor,
      'allowLightThresholdEdit': useLightSensor,
      'allowTemperatureThresholdEdit': useTemperatureSensor,
    };

    setState(() {
      zone.addAll({
        ...zonePermissionOverrides,
        'allowThresholdEdit': useHumiditySensor ||
            useGasSensor ||
            useLightSensor ||
            useTemperatureSensor,
      });
      _thresholdPermissionOverridesByZoneId[zoneId] = zonePermissionOverrides;
    });
    await _saveZoneOverridesLocally();

    final synced = await _syncZoneConfig();
    if (synced) {
      await _fetchZoneConfig();
      return;
    }

    final response = await _postFirstSuccessful(
      const [
        '/update-zone-capabilities',
        '/update-zone-sensors',
        '/update-zone-config',
        '/update-zone',
        '/edit-zone',
      ],
      body: {
        'id': zoneId,
        'zone_id': zoneId,
        'zoneId': zoneId,
        'allowValveControl': useValveControl,
        'allow_ev_control': useValveControl,
        'canControlValve': useValveControl,
        'enabledSensors': [
          if (useHumiditySensor) 'humidity',
          if (useGasSensor) 'gas',
          if (useLightSensor) 'light',
          if (useTemperatureSensor) 'temperature',
        ],
        'useHumiditySensor': useHumiditySensor,
        'useGasSensor': useGasSensor,
        'useLightSensor': useLightSensor,
        'useTemperatureSensor': useTemperatureSensor,
        'use_humidity_sensor': useHumiditySensor,
        'use_gas_sensor': useGasSensor,
        'use_light_sensor': useLightSensor,
        'use_temperature_sensor': useTemperatureSensor,
        'allowHumidityThresholdEdit': useHumiditySensor,
        'allowGasThresholdEdit': useGasSensor,
        'allowLightThresholdEdit': useLightSensor,
        'allowTemperatureThresholdEdit': useTemperatureSensor,
        'allow_humidity_threshold_edit': useHumiditySensor,
        'allow_gas_threshold_edit': useGasSensor,
        'allow_light_threshold_edit': useLightSensor,
        'allow_temperature_threshold_edit': useTemperatureSensor,
        'canEditHumidityThreshold': useHumiditySensor,
        'canEditGasThreshold': useGasSensor,
        'canEditLightThreshold': useLightSensor,
        'canEditTemperatureThreshold': useTemperatureSensor,
        'allowThresholdEdit':
        useHumiditySensor || useGasSensor || useLightSensor || useTemperatureSensor,
      },
    );

    if (!mounted) return;
    if (response == null || response.statusCode >= 400) {
      await _fetchDashboardSnapshot();
      if (!mounted) return;

      final refreshed = zones.where((z) => _toInt(z['id']) == zoneId).toList();
      final backendApplied = refreshed.isNotEmpty &&
          _zoneSensorsMatch(
            refreshed.first,
            useValveControl: useValveControl,
            useHumiditySensor: useHumiditySensor,
            useGasSensor: useGasSensor,
            useLightSensor: useLightSensor,
            useTemperatureSensor: useTemperatureSensor,
          );

      if (!backendApplied) {
        setState(() {
          zone.addAll(previousZoneValues);
          if (previousOverrides == null) {
            _thresholdPermissionOverridesByZoneId.remove(zoneId);
          } else {
            _thresholdPermissionOverridesByZoneId[zoneId] = previousOverrides;
          }
        });
        await _saveZoneOverridesLocally();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('Echec mise a jour capteurs', 'Failed to update sensors'))),
        );
      }
    }
  }

  Widget _buildZoneCard(Map<String, dynamic> zone) {
    final isManual = _isManualMode(zone['ev_mode']);
    final valveOn = _isValveOn(zone['valve']);
    final canControlValve = _canControlValve(zone);
    final canEditThresholds = _canEditAnyThreshold(zone);

    return Card(
      color: Colors.white.withOpacity(0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      elevation: 5,
      margin: const EdgeInsets.only(bottom: 15),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleZoneCardScrollNotification,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  zoneLabel(zone),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                if (_usesHumiditySensor(zone))
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_tr('Humidite', 'Humidity')}: ${_toDouble(zone['humidity']).toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: getColor(
                            _toDouble(zone['humidity']),
                            _toDouble(zone['thresholdHumidity']),
                          ),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('${_tr('Seuil', 'Threshold')}: ${_toDouble(zone['thresholdHumidity']).toStringAsFixed(0)}%'),
                    ],
                  ),
                if (_usesHumiditySensor(zone)) const SizedBox(height: 8),
                if (_usesGasSensor(zone))
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_tr('Gaz', 'Gas')}: ${_toDouble(zone['nutrition'] ?? zone['gaz']).toStringAsFixed(0)} ppm',
                        style: TextStyle(
                          color: getColor(
                            _toDouble(zone['nutrition'] ?? zone['gaz']),
                            _toDouble(zone['thresholdNutrition'] ?? zone['thresholdgaz'] ?? zone['thresholdGaz']),
                          ),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('${_tr('Seuil', 'Threshold')}: ${_toDouble(zone['thresholdNutrition'] ?? zone['thresholdgaz'] ?? zone['thresholdGaz']).toStringAsFixed(0)} ppm'),
                    ],
                  ),
                if (_usesGasSensor(zone)) const SizedBox(height: 8),
                if (_usesLightSensor(zone))
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_tr('Lumiere', 'Light')}: ${_toDouble(zone['light']).toStringAsFixed(0)} lx',
                        style: TextStyle(
                          color: getColor(
                            _toDouble(zone['light']),
                            _toDouble(zone['thresholdLight']),
                          ),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('${_tr('Seuil', 'Threshold')}: ${_toDouble(zone['thresholdLight']).toStringAsFixed(0)} lx'),
                    ],
                  ),
                if (_usesLightSensor(zone)) const SizedBox(height: 8),
                if (_usesTemperatureSensor(zone))
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_tr('Temperature', 'Temperature')}: ${_toDouble(zone['temperature']).toStringAsFixed(1)} °C',
                        style: TextStyle(
                          color: getColor(
                            _toDouble(zone['temperature']),
                            _toDouble(zone['thresholdTemperature']),
                          ),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('${_tr('Seuil', 'Threshold')}: ${_toDouble(zone['thresholdTemperature']).toStringAsFixed(1)} °C'),
                    ],
                  ),
                if (_usesTemperatureSensor(zone)) const SizedBox(height: 8),
                _buildZoneAlertBox(zone),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_tr('Mode electrovanne', 'Valve mode')}: ${_modeLabel(zone['ev_mode'])}'),
                    Switch(
                      value: isManual,
                      onChanged: canControlValve ? (value) => _setZoneMode(zone, value) : null,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _tr('Commande électrovanne', 'Valve command'),
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    ElevatedButton.icon(
                      onPressed: (isManual && canControlValve)
                          ? () => _toggleValveManual(zone)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: valveOn ? Colors.red.shade600 : Colors.green.shade600,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade300,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 6,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      icon: Icon(
                        valveOn ? Icons.power_off : Icons.power,
                        color: Colors.white,
                      ),
                      label: Text(
                        valveOn ? _tr('COUPER', 'CLOSE') : _tr('OUVRIR', 'OPEN'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_tr('Etat electrovanne', 'Valve state')),
                    _buildValveLamp(zone['valve']),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: canEditThresholds ? () => showEditDialog(zone) : null,
                        icon: const Icon(Icons.tune, size: 16),
                        label: Text(
                          _tr('Seuils', 'Thresholds'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                          minimumSize: const Size.fromHeight(40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          alignment: Alignment.center,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => showEditNameDialog(zone),
                        icon: const Icon(Icons.edit),
                        label: Text(
                          _tr('Nom', 'Name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade600,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => showEditSensorsDialog(zone),
                    icon: const Icon(Icons.sensors),
                    label: Text(_tr('Configurer les capteurs', 'Configure sensors')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal.shade700,
                      side: BorderSide(color: Colors.teal.shade300, width: 1.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeZoneCard(Map<String, dynamic> zone, int zoneGlobalIndex) {
    final isManual = _isManualMode(zone['ev_mode']);
    final valveOn = _isValveOn(zone['valve']);
    final canControlValve = _canControlValve(zone);
    final canEditThresholds = _canEditAnyThreshold(zone);

    return Card(
      color: Colors.white.withOpacity(0.95),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      elevation: 4,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) =>
                    _handleLandscapeZoneScrollNotification(notification, zoneGlobalIndex),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zoneLabel(zone),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      if (_usesHumiditySensor(zone))
                        Text(
                          'H: ${_toDouble(zone['humidity']).toStringAsFixed(0)}%  /  ${_toDouble(zone['thresholdHumidity']).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: getColor(
                              _toDouble(zone['humidity']),
                              _toDouble(zone['thresholdHumidity']),
                            ),
                          ),
                        ),
                      if (_usesGasSensor(zone))
                        Text(
                          'G: ${_toDouble(zone['nutrition'] ?? zone['gaz']).toStringAsFixed(0)} ppm  /  ${_toDouble(zone['thresholdNutrition'] ?? zone['thresholdgaz'] ?? zone['thresholdGaz']).toStringAsFixed(0)} ppm',
                          style: TextStyle(
                            fontSize: 12,
                            color: getColor(
                              _toDouble(zone['nutrition'] ?? zone['gaz']),
                              _toDouble(zone['thresholdNutrition'] ?? zone['thresholdgaz'] ?? zone['thresholdGaz']),
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (_usesLightSensor(zone))
                        Text(
                          'L: ${_toDouble(zone['light']).toStringAsFixed(0)} lx  /  ${_toDouble(zone['thresholdLight']).toStringAsFixed(0)} lx',
                          style: TextStyle(
                            fontSize: 12,
                            color: getColor(
                              _toDouble(zone['light']),
                              _toDouble(zone['thresholdLight']),
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (_usesTemperatureSensor(zone))
                        Text(
                          'T: ${_toDouble(zone['temperature']).toStringAsFixed(1)} °C  /  ${_toDouble(zone['thresholdTemperature']).toStringAsFixed(1)} °C',
                          style: TextStyle(
                            fontSize: 12,
                            color: getColor(
                              _toDouble(zone['temperature']),
                              _toDouble(zone['thresholdTemperature']),
                            ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      const SizedBox(height: 4),
                      _buildLandscapeAlertInline(zone),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_tr('Mode', 'Mode')}: ${_modeLabel(zone['ev_mode'])}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Transform.scale(
                            scale: 0.82,
                            child: Switch(
                              value: isManual,
                              onChanged: canControlValve
                                  ? (value) => _setZoneMode(zone, value)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: (isManual && canControlValve)
                        ? () => _toggleValveManual(zone)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                      valveOn ? Colors.red.shade600 : Colors.green.shade600,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      minimumSize: const Size.fromHeight(30),
                    ),
                    child: Text(
                      valveOn ? _tr('COUPER', 'CLOSE') : _tr('OUVRIR', 'OPEN'),
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: canEditThresholds ? () => showEditDialog(zone) : null,
                  icon: const Icon(Icons.tune, size: 18),
                  tooltip: _tr('Seuils', 'Thresholds'),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () => showEditNameDialog(zone),
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: _tr('Nom', 'Name'),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () => showEditSensorsDialog(zone),
                  icon: const Icon(Icons.sensors, size: 18),
                  tooltip: _tr('Capteurs', 'Sensors'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final bottomActionsClearance = 110.0 + MediaQuery.of(context).padding.bottom;
    final selectedValue = (selectedZoneId != null &&
        zones.any((z) => _toInt(z['id']) == selectedZoneId))
        ? selectedZoneId
        : null;
    final landscapePageCount = _landscapePageCount();
    final visibleLandscapeZones = _visibleLandscapeZones();
    final activeZoneAlerts = _collectActiveZoneAlerts();
    final dosagePlan = _dosagePlan;
    final tankCapacityLiters = _tankCapacityLiters ??
      _toPositiveDoubleOrNull(dosagePlan?['tank_capacity_liters']);

    return Scaffold(
      endDrawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.green.shade600, Colors.green.shade400],
                  ),
                ),
                child: const Text(
                  'Menu',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(_tr('Historique', 'History')),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _openHistory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.local_pharmacy_outlined),
                title: Text(_tr('Dosage produits', 'Products dosing')),
                subtitle: Text(_tr('Produits A, B, C', 'Products A, B, C')),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _openDosageSettings();
                },
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(_tr('Langue', 'Language')),
                subtitle: Text(_isEnglish ? 'English' : 'Français'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _showLanguageDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(_tr('Deconnexion', 'Logout')),
                onTap: _logout,
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        offset: _showBottomActions ? Offset.zero : const Offset(0, 1.3),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _showBottomActions ? 1 : 0,
          child: IgnorePointer(
            ignoring: !_showBottomActions,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: FloatingActionButton.extended(
                        heroTag: 'add_zone_fab',
                        onPressed: addZone,
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        icon: const Icon(Icons.add_circle_outline),
                        label: Text(
                          _tr('Ajouter zone', 'Add zone'),
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FloatingActionButton.extended(
                        heroTag: 'remove_zone_fab',
                        onPressed: selectedZoneId == null ? null : _confirmAndRemoveZone,
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        icon: const Icon(Icons.delete_outline),
                        label: Text(
                          _tr('Supprimer zone', 'Remove zone'),
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.green.shade50, Colors.blue.shade50],
          ),
        ),
        child: CustomScrollView(
          controller: _mainScrollController,
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              pinned: false,
              title: Text(
                _tr('Irrigation Intelligente', 'Smart Irrigation'),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
              ),
              centerTitle: true,
              flexibleSpace: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.green.shade600, Colors.green.shade400],
                  ),
                ),
              ),
              elevation: 10,
              shadowColor: Colors.black.withOpacity(0.4),
              actions: [
                Builder(
                  builder: (context) => IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white),
                    tooltip: _tr('Menu', 'Menu'),
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                  ),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Row(
                    children: [
                      Text(
                        _tr('Zone sélectionnée:', 'Selected zone:'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.green.shade300, width: 2),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.green.withOpacity(0.1),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: DropdownButton<int>(
                            value: selectedValue,
                            underline: const SizedBox(),
                            isExpanded: true,
                            items: zones
                                .map(
                                  (zone) => DropdownMenuItem<int>(
                                value: _toInt(zone['id']),
                                child: Text(
                                  zoneLabel(zone),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                selectedZoneId = value;
                                final idx =
                                zones.indexWhere((z) => _toInt(z['id']) == value);
                                if (idx >= 0) {
                                  currentZoneIndex = idx;
                                  if (isLandscape) {
                                    currentLandscapePage = idx ~/ 4;
                                  } else {
                                    _pageController.animateToPage(
                                      idx,
                                      duration: const Duration(milliseconds: 250),
                                      curve: Curves.easeInOut,
                                    );
                                  }
                                }
                              });
                              _scrollToZoneSection();
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildGlobalAlertsCard(activeZoneAlerts),
                  const SizedBox(height: 20),
                  Card(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: Colors.green.shade200, width: 2),
                    ),
                    elevation: 8,
                    shadowColor: Colors.green.withOpacity(0.3),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.green.shade50, Colors.blue.shade50],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Text(
                              _tr('Environnement Global', 'Global environment'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  children: [
                                    const Icon(
                                      Icons.thermostat,
                                      color: Colors.orange,
                                      size: 30,
                                    ),
                                    Text('${environment['temperature'] ?? '--'} °C'),
                                  ],
                                ),
                                Column(
                                  children: [
                                    const Icon(
                                      Icons.water_drop,
                                      color: Colors.blue,
                                      size: 30,
                                    ),
                                    Text('${environment['humidity_air'] ?? '--'} %'),
                                  ],
                                ),
                                Column(
                                  children: [
                                    const Icon(
                                      Icons.science,
                                      color: Colors.purple,
                                      size: 30,
                                    ),
                                    Text('${_tr('pH', 'pH')}: ${environment['water_ph'] ?? '--'}'),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 25),
                            CircularPercentIndicator(
                              radius: 70.0,
                              lineWidth: 12.0,
                              percent: (_toDouble(environment['water_level']) / 100).clamp(0.0, 1.0),
                              center: Text('${environment['water_level'] ?? '--'} %'),
                              progressColor: _toDouble(environment['water_level']) < 20
                                  ? Colors.red
                                  : Colors.blue,
                              backgroundColor: Colors.blue.shade100,
                            ),
                            const SizedBox(height: 10),
                            Text(_tr('Niveau Citerne', 'Tank level')),
                            if (tankCapacityLiters != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                _tr(
                                  'Capacite: ${_formatPlanNumber(tankCapacityLiters, decimals: 0)} L',
                                  'Capacity: ${_formatPlanNumber(tankCapacityLiters, decimals: 0)} L',
                                ),
                                style: TextStyle(
                                  color: Colors.grey.shade800,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    key: _zoneSectionKey,
                    height: isLandscape ? 640 : 460,
                    child: zones.isEmpty
                        ? Center(
                      child: Text(
                        _tr('Aucune zone', 'No zone'),
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    )
                        : isLandscape
                        ? GridView.builder(
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: visibleLandscapeZones.length,
                      gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        mainAxisExtent: 312,
                      ),
                      itemBuilder: (context, index) {
                        final zone = visibleLandscapeZones[index];
                        final globalIndex = (currentLandscapePage * 4) + index;
                        return _buildLandscapeZoneCard(zone, globalIndex);
                      },
                    )
                        : PageView.builder(
                      controller: _pageController,
                      itemCount: zones.length,
                      onPageChanged: (index) {
                        setState(() {
                          currentZoneIndex = index;
                          selectedZoneId = _toInt(zones[index]['id']);
                        });
                      },
                      itemBuilder: (context, index) {
                        final zone = zones[index];
                        return _buildZoneCard(zone);
                      },
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isLandscape) {
                              if (currentLandscapePage > 0) {
                                setState(() {
                                  currentLandscapePage--;
                                  final firstIndex = currentLandscapePage * 4;
                                  if (firstIndex < zones.length) {
                                    selectedZoneId = _toInt(zones[firstIndex]['id']);
                                    currentZoneIndex = firstIndex;
                                  }
                                });
                              }
                            } else if (currentZoneIndex > 0) {
                              _pageController.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.ease,
                              );
                            }
                          },
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: Text(_tr('Précédent', 'Previous'), style: const TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade600,
                            foregroundColor: Colors.white,
                            padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.green.shade300, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Text(
                          zones.isEmpty
                              ? _tr('Zone 0 / 0', 'Zone 0 / 0')
                              : isLandscape
                              ? _tr('Groupe ${currentLandscapePage + 1} / $landscapePageCount', 'Group ${currentLandscapePage + 1} / $landscapePageCount')
                              : 'Zone ${currentZoneIndex + 1} / ${zones.length}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.green,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isLandscape) {
                              if (currentLandscapePage < landscapePageCount - 1) {
                                setState(() {
                                  currentLandscapePage++;
                                  final firstIndex = currentLandscapePage * 4;
                                  if (firstIndex < zones.length) {
                                    selectedZoneId = _toInt(zones[firstIndex]['id']);
                                    currentZoneIndex = firstIndex;
                                  }
                                });
                              }
                            } else if (currentZoneIndex < zones.length - 1) {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.ease,
                              );
                            }
                          },
                          icon: const Icon(Icons.arrow_forward, size: 18),
                          label: Text(_tr('Suivant', 'Next'), style: const TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade600,
                            foregroundColor: Colors.white,
                            padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 6,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: bottomActionsClearance),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoneNamePin {
  const _ZoneNamePin({
    required this.name,
    required this.expiresAt,
  });

  final String name;
  final DateTime expiresAt;
}

class _DosageSettingsScreen extends StatefulWidget {
  const _DosageSettingsScreen({
    required this.isEnglish,
    required this.storageKey,
    required this.baseUrl,
    required this.token,
    this.initialDosagePlan,
  });

  final bool isEnglish;
  final String storageKey;
  final String baseUrl;
  final String? token;
  final Map<String, dynamic>? initialDosagePlan;

  @override
  State<_DosageSettingsScreen> createState() => _DosageSettingsScreenState();
}

class _DosageSettingsScreenState extends State<_DosageSettingsScreen> {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final TextEditingController _tankCapacityController = TextEditingController();
  Map<String, dynamic>? _latestDosagePlan;
  Map<String, dynamic>? _lastStableDosagePlan;
  double? _previewWaterLevelPercent;
  Timer? _previewDebounceTimer;
  int _previewRequestVersion = 0;

  final Map<String, TextEditingController> _doseControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  final Map<String, TextEditingController> _minControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  final Map<String, TextEditingController> _maxControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  final Map<String, TextEditingController> _rodPitchControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  final Map<String, TextEditingController> _stepsPerTurnControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  final Map<String, TextEditingController> _mlPerMmControllers = {
    'A': TextEditingController(),
    'B': TextEditingController(),
    'C': TextEditingController(),
  };

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _attachPreviewListeners();
    _latestDosagePlan = widget.initialDosagePlan == null
        ? null
        : Map<String, dynamic>.from(widget.initialDosagePlan!);
    _lastStableDosagePlan = _latestDosagePlan == null
      ? null
      : Map<String, dynamic>.from(_latestDosagePlan!);
    _loadExistingConfig();
  }

    Map<String, dynamic>? get _visibleDosagePlan =>
      _latestDosagePlan ?? _lastStableDosagePlan;

  void _attachPreviewListeners() {
    _tankCapacityController.addListener(_schedulePlanPreviewRefresh);
    for (final product in const ['A', 'B', 'C']) {
      _doseControllers[product]!.addListener(_schedulePlanPreviewRefresh);
      _minControllers[product]!.addListener(_schedulePlanPreviewRefresh);
      _maxControllers[product]!.addListener(_schedulePlanPreviewRefresh);
      _rodPitchControllers[product]!.addListener(_schedulePlanPreviewRefresh);
      _stepsPerTurnControllers[product]!.addListener(_schedulePlanPreviewRefresh);
      _mlPerMmControllers[product]!.addListener(_schedulePlanPreviewRefresh);
    }
  }

  void _schedulePlanPreviewRefresh() {
    _previewDebounceTimer?.cancel();
    _previewDebounceTimer = Timer(
      const Duration(milliseconds: 350),
      _refreshPlanPreview,
    );
  }

  Map<String, dynamic>? _buildPreviewPayload() {
    final tankCapacityLiters = _parseStrictPositive(_tankCapacityController.text);
    if (tankCapacityLiters == null) return null;

    final waterLevelPercent = _previewWaterLevelPercent ??
        _toDouble(_visibleDosagePlan?['water_level_percent'], fallback: 100);
    final safeWaterLevelPercent = waterLevelPercent.clamp(0, 100).toDouble();
    final waterLiters = (safeWaterLevelPercent / 100) * tankCapacityLiters;

    final payload = <String, Map<String, double>>{};
    for (final product in const ['A', 'B', 'C']) {
      final dose = _parsePositiveOrZero(_doseControllers[product]!.text);
      final min = _parsePositiveOrZero(_minControllers[product]!.text);
      final max = _parsePositiveOrZero(_maxControllers[product]!.text);
      final rodPitch = _parseStrictPositive(_rodPitchControllers[product]!.text);
      final stepsPerTurn = _parseStrictPositive(_stepsPerTurnControllers[product]!.text);
      final mlPerMm = _parseStrictPositive(_mlPerMmControllers[product]!.text);

      if (dose == null ||
          min == null ||
          max == null ||
          rodPitch == null ||
          stepsPerTurn == null ||
          mlPerMm == null ||
          max < min) {
        return null;
      }

      payload[product] = {
        'dose_ml_per_l': dose,
        'min_ml_per_l': min,
        'max_ml_per_l': max,
        'rod_pitch_mm': rodPitch,
        'steps_per_turn': stepsPerTurn,
        'ml_per_mm': mlPerMm,
      };
    }

    return {
      'dosage_config': payload,
      'tank_capacity_liters': tankCapacityLiters,
      'water_liters': waterLiters,
    };
  }

  double _clampDouble(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  Map<String, dynamic>? _computeLocalPlanPreview() {
    final tankCapacityLiters = _parseStrictPositive(_tankCapacityController.text);
    if (tankCapacityLiters == null) return null;

    final waterLevelPercent = (_previewWaterLevelPercent ??
            _toDouble(_visibleDosagePlan?['water_level_percent'], fallback: 100))
        .clamp(0, 100)
        .toDouble();
    final waterLiters = (waterLevelPercent / 100) * tankCapacityLiters;

    final products = <String, dynamic>{};
    double totalDoseMl = 0;
    int totalSteps = 0;

    for (final product in const ['A', 'B', 'C']) {
      final dosePerL = _parsePositiveOrZero(_doseControllers[product]!.text);
      final minPerL = _parsePositiveOrZero(_minControllers[product]!.text);
      final maxPerL = _parsePositiveOrZero(_maxControllers[product]!.text);
      final rodPitch = _parseStrictPositive(_rodPitchControllers[product]!.text);
      final stepsPerTurn = _parseStrictPositive(_stepsPerTurnControllers[product]!.text);
      final mlPerMm = _parseStrictPositive(_mlPerMmControllers[product]!.text);

      if (dosePerL == null ||
          minPerL == null ||
          maxPerL == null ||
          rodPitch == null ||
          stepsPerTurn == null ||
          mlPerMm == null ||
          maxPerL < minPerL) {
        return null;
      }

      final theoreticalDoseMl = waterLiters * dosePerL;
      final minDoseMlAbs = waterLiters * minPerL;
      final maxDoseMlAbs = waterLiters * maxPerL;
      final targetDoseMl = _clampDouble(theoreticalDoseMl, minDoseMlAbs, maxDoseMlAbs);
      final courseMm = targetDoseMl / mlPerMm;
      final turns = courseMm / rodPitch;
      final stepsFloat = turns * stepsPerTurn;
      final steps = stepsFloat.ceil();

      products[product] = {
        'theoretical_dose_ml': theoreticalDoseMl,
        'min_dose_ml_abs': minDoseMlAbs,
        'max_dose_ml_abs': maxDoseMlAbs,
        'target_dose_ml': targetDoseMl,
        'course_mm': courseMm,
        'turns': turns,
        'steps_float': stepsFloat,
        'steps': steps,
      };

      totalDoseMl += targetDoseMl;
      totalSteps += steps;
    }

    return {
      'water_level_percent': waterLevelPercent,
      'tank_capacity_liters': tankCapacityLiters,
      'water_liters': waterLiters,
      'products': products,
      'totals': {
        'target_dose_ml': totalDoseMl,
        'steps': totalSteps,
      },
    };
  }

  Future<void> _refreshPlanPreview() async {
    final authToken = (widget.token ?? '').trim();
    final localPlan = _computeLocalPlanPreview();
    if (localPlan != null && mounted) {
      setState(() {
        _latestDosagePlan = localPlan;
        _lastStableDosagePlan = Map<String, dynamic>.from(localPlan);
      });
    }

    if (authToken.isEmpty) return;

    final payload = _buildPreviewPayload();
    if (payload == null) return;

    final requestVersion = ++_previewRequestVersion;

    try {
      final response = await http
          .post(
            Uri.parse('${widget.baseUrl}/dosage/calculate'),
            headers: _authHeaders(),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted || requestVersion != _previewRequestVersion) return;
      if (response.statusCode >= 400) return;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['dosage_plan'] is! Map) return;

      setState(() {
        final plan = Map<String, dynamic>.from(decoded['dosage_plan'] as Map);
        _latestDosagePlan = plan;
        _lastStableDosagePlan = Map<String, dynamic>.from(plan);
        _previewWaterLevelPercent = _toDouble(
          plan['water_level_percent'],
          fallback: _previewWaterLevelPercent ?? 100,
        ).clamp(0, 100).toDouble();
      });
    } catch (_) {
      // Ignore preview failures to keep manual entry fluid.
    }
  }

  String _formatPlanNumber(dynamic value, {int decimals = 2}) {
    final parsed = double.tryParse((value ?? '').toString());
    if (parsed == null || parsed.isNaN || parsed.isInfinite) return '--';
    return parsed.toStringAsFixed(decimals);
  }

  Widget _buildPlanValueLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade800),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalPlanSummary() {
    final plan = _visibleDosagePlan;
    if (plan == null) return const SizedBox.shrink();
    final totalsRaw = plan['totals'];
    final totals = totalsRaw is Map
        ? Map<String, dynamic>.from(totalsRaw)
        : <String, dynamic>{};

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr('Resultats calcul serveur', 'Server calculation results'),
            style: TextStyle(
              color: Colors.teal.shade700,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _buildPlanValueLine(
            _tr('Niveau eau', 'Water level'),
            '${_formatPlanNumber(plan['water_level_percent'])} %',
          ),
          _buildPlanValueLine(
            _tr('Eau estimee', 'Estimated water'),
            '${_formatPlanNumber(plan['water_liters'])} L',
          ),
          _buildPlanValueLine(
            _tr('Total dose', 'Total dose'),
            '${_formatPlanNumber(totals['target_dose_ml'])} mL',
          ),
          _buildPlanValueLine(
            _tr('Total pas', 'Total steps'),
            '${(totals['steps'] ?? 0).toString()} ${_tr('pas', 'steps')}',
          ),
        ],
      ),
    );
  }

  Widget _buildProductPlanSummary(String product) {
    final plan = _visibleDosagePlan;
    if (plan == null) return const SizedBox.shrink();

    final productsRaw = plan['products'];
    if (productsRaw is! Map || productsRaw[product] is! Map) {
      return const SizedBox.shrink();
    }

    final productMap = Map<String, dynamic>.from(productsRaw[product] as Map);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr('Resultats produit $product', 'Product $product results'),
            style: TextStyle(
              color: Colors.teal.shade700,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          _buildPlanValueLine(
            _tr('Dose theorique', 'Theoretical dose'),
            '${_formatPlanNumber(productMap['theoretical_dose_ml'])} mL',
          ),
          _buildPlanValueLine(
            _tr('Dose min abs', 'Min absolute dose'),
            '${_formatPlanNumber(productMap['min_dose_ml_abs'])} mL',
          ),
          _buildPlanValueLine(
            _tr('Dose max abs', 'Max absolute dose'),
            '${_formatPlanNumber(productMap['max_dose_ml_abs'])} mL',
          ),
          _buildPlanValueLine(
            _tr('Dose cible', 'Target dose'),
            '${_formatPlanNumber(productMap['target_dose_ml'])} mL',
          ),
          _buildPlanValueLine(
            _tr('Course tige filetee', 'Threaded rod travel'),
            '${_formatPlanNumber(productMap['course_mm'])} mm',
          ),
          _buildPlanValueLine(
            _tr('Tours vis', 'Lead screw turns'),
            _formatPlanNumber(productMap['turns']),
          ),
          _buildPlanValueLine(
            _tr('Pas moteur (flottant)', 'Motor steps (float)'),
            _formatPlanNumber(productMap['steps_float']),
          ),
          _buildPlanValueLine(
            _tr('Pas moteur commandes', 'Commanded motor steps'),
            '${(productMap['steps'] ?? 0).toString()} ${_tr('pas', 'steps')}',
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _previewDebounceTimer?.cancel();
    _tankCapacityController.dispose();
    for (final c in _doseControllers.values) {
      c.dispose();
    }
    for (final c in _minControllers.values) {
      c.dispose();
    }
    for (final c in _maxControllers.values) {
      c.dispose();
    }
    for (final c in _rodPitchControllers.values) {
      c.dispose();
    }
    for (final c in _stepsPerTurnControllers.values) {
      c.dispose();
    }
    for (final c in _mlPerMmControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _tr(String fr, String en) => widget.isEnglish ? en : fr;

  Map<String, String> _authHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    final authToken = (widget.token ?? '').trim();
    if (authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    return headers;
  }

  void _applyConfigMap(
    Map<String, dynamic> decoded, {
    double? tankCapacityLiters,
  }) {
    final safeCapacity = (tankCapacityLiters != null && tankCapacityLiters > 0)
        ? tankCapacityLiters
        : null;

    double? resolvePerLiterValue(Map entry, String perLiterKey, String legacyAbsKey) {
      final directPerLiter = _toDouble(entry[perLiterKey], fallback: double.nan);
      if (!directPerLiter.isNaN && directPerLiter.isFinite && directPerLiter >= 0) {
        return directPerLiter;
      }

      if (safeCapacity == null) return null;
      final legacyAbs = _toDouble(entry[legacyAbsKey], fallback: double.nan);
      if (legacyAbs.isNaN || !legacyAbs.isFinite || legacyAbs < 0) {
        return null;
      }

      return legacyAbs / safeCapacity;
    }

    for (final product in const ['A', 'B', 'C']) {
      final entry = decoded[product];
      if (entry is! Map) continue;

      final dosePerL = _toDouble(entry['dose_ml_per_l'], fallback: 0);
      final minPerL = resolvePerLiterValue(entry, 'min_ml_per_l', 'min_ml');
      final maxPerL = resolvePerLiterValue(entry, 'max_ml_per_l', 'max_ml');

      _doseControllers[product]!.text = _toText(entry['dose_ml_per_l']);
      _minControllers[product]!.text = _toText(minPerL ?? dosePerL);
      _maxControllers[product]!.text = _toText(maxPerL ?? dosePerL);
      _rodPitchControllers[product]!.text = _toText(entry['rod_pitch_mm']);
      _stepsPerTurnControllers[product]!.text = _toText(entry['steps_per_turn']);
      _mlPerMmControllers[product]!.text = _toText(entry['ml_per_mm']);
    }
  }

  Future<void> _loadExistingConfig() async {
    bool loadedFromServer = false;

    try {
      final authToken = (widget.token ?? '').trim();
      if (authToken.isNotEmpty) {
        final response = await http
            .get(
              Uri.parse('${widget.baseUrl}/dosage-config'),
              headers: _authHeaders(),
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['dosage_config'] is Map) {
            final capacity = _parseStrictPositive(
              _toText(decoded['tank_capacity_liters']),
            );
            _tankCapacityController.text = _toText(decoded['tank_capacity_liters']);
            _applyConfigMap(
              Map<String, dynamic>.from(decoded['dosage_config'] as Map),
              tankCapacityLiters: capacity,
            );
            loadedFromServer = true;
          }
        }
      }
    } catch (_) {
      // Ignore server load failure, local fallback below.
    }

    if (!loadedFromServer) {
      final raw = await _secureStorage.read(key: widget.storageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            if (decoded['dosage_config'] is Map) {
              final capacity = _parseStrictPositive(
                _toText(decoded['tank_capacity_liters']),
              );
              _tankCapacityController.text = _toText(decoded['tank_capacity_liters']);
              _applyConfigMap(
                Map<String, dynamic>.from(decoded['dosage_config'] as Map),
                tankCapacityLiters: capacity,
              );
            } else {
              _applyConfigMap(Map<String, dynamic>.from(decoded));
            }
          }
        } catch (_) {
          // ignore malformed local payload
        }
      }
    }

    if (mounted) setState(() {});
    await _tryLoadPlanFromDashboard();
    _schedulePlanPreviewRefresh();
  }

  Future<void> _tryLoadPlanFromDashboard() async {
    try {
      final authToken = (widget.token ?? '').trim();
      if (authToken.isEmpty) return;

      final response = await http
          .get(
            Uri.parse('${widget.baseUrl}/dashboard'),
            headers: _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return;

      final environmentRaw = decoded['environment'];
      if (environmentRaw is Map) {
        final waterLevel = _toDouble(environmentRaw['water_level'], fallback: double.nan);
        if (!waterLevel.isNaN && !waterLevel.isInfinite) {
          _previewWaterLevelPercent = waterLevel.clamp(0, 100).toDouble();
        }
      }

      if (decoded['dosage_plan'] is! Map) return;

      if (!mounted) return;
      setState(() {
        final plan = Map<String, dynamic>.from(decoded['dosage_plan'] as Map);
        _latestDosagePlan = plan;
        _lastStableDosagePlan = Map<String, dynamic>.from(plan);
        _previewWaterLevelPercent = _toDouble(
          plan['water_level_percent'],
          fallback: _previewWaterLevelPercent ?? 100,
        ).clamp(0, 100).toDouble();
      });
    } catch (_) {
      // Keep existing plan if dashboard fetch fails.
    }
  }

  String _toText(dynamic value) {
    if (value == null) return '';
    if (value is num) return value.toString();
    return value.toString().trim();
  }

  double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString()) ?? fallback;
  }

  double? _parsePositiveOrZero(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    final parsed = double.tryParse(normalized);
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  double? _parseStrictPositive(String raw) {
    final parsed = _parsePositiveOrZero(raw);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  Future<void> _save() async {
    if (_saving) return;

    final payload = <String, Map<String, double>>{};
    final tankCapacityLiters = _parseStrictPositive(_tankCapacityController.text);
    if (tankCapacityLiters == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr('Capacite de citerne invalide', 'Invalid tank capacity'),
          ),
        ),
      );
      return;
    }

    for (final product in const ['A', 'B', 'C']) {
      final dose = _parsePositiveOrZero(_doseControllers[product]!.text);
      final min = _parsePositiveOrZero(_minControllers[product]!.text);
      final max = _parsePositiveOrZero(_maxControllers[product]!.text);
      final rodPitch = _parseStrictPositive(_rodPitchControllers[product]!.text);
      final stepsPerTurn = _parseStrictPositive(_stepsPerTurnControllers[product]!.text);
      final mlPerMm = _parseStrictPositive(_mlPerMmControllers[product]!.text);

      if (dose == null || min == null || max == null || rodPitch == null || stepsPerTurn == null || mlPerMm == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                'Valeurs invalides pour le produit $product',
                'Invalid values for product $product',
              ),
            ),
          ),
        );
        return;
      }

      if (max < min) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                'Le max doit etre >= min pour le produit $product',
                'Max must be >= min for product $product',
              ),
            ),
          ),
        );
        return;
      }

      payload[product] = {
        'dose_ml_per_l': dose,
        'min_ml_per_l': min,
        'max_ml_per_l': max,
        'rod_pitch_mm': rodPitch,
        'steps_per_turn': stepsPerTurn,
        'ml_per_mm': mlPerMm,
      };
    }

    setState(() {
      _saving = true;
    });

    try {
      await _secureStorage.write(
        key: widget.storageKey,
        value: jsonEncode({
          'dosage_config': payload,
          'tank_capacity_liters': tankCapacityLiters,
        }),
      );

      bool serverSynced = false;
      final authToken = (widget.token ?? '').trim();
      Map<String, dynamic>? nextPlan;
      if (authToken.isNotEmpty) {
        final response = await http
            .post(
              Uri.parse('${widget.baseUrl}/dosage-config'),
              headers: _authHeaders(),
              body: jsonEncode({
                'dosage_config': payload,
                'tank_capacity_liters': tankCapacityLiters,
              }),
            )
            .timeout(const Duration(seconds: 12));
        serverSynced = response.statusCode < 400;
        if (serverSynced) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded['dosage_plan'] is Map) {
              nextPlan = Map<String, dynamic>.from(decoded['dosage_plan'] as Map);
            }
          } catch (_) {
            // Ignore malformed server payload.
          }
        }
      }

      if (!mounted) return;
      if (!serverSynced) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                'Configuration locale enregistree, echec de synchronisation serveur',
                'Local configuration saved, server synchronization failed',
              ),
            ),
          ),
        );
        return;
      }

      setState(() {
        if (nextPlan != null) {
          _latestDosagePlan = nextPlan;
          _lastStableDosagePlan = Map<String, dynamic>.from(nextPlan);
          _previewWaterLevelPercent = _toDouble(
            nextPlan['water_level_percent'],
            fallback: _previewWaterLevelPercent ?? 100,
          ).clamp(0, 100).toDouble();
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Configuration enregistree', 'Configuration saved'))),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
    }
  }

  Widget _buildProductCard(String product) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tr('Produit $product', 'Product $product'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _doseControllers[product],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _tr('Dose cible (mL/L)', 'Target dose (mL/L)'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _minControllers[product],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _tr('Dose min (mL/L)', 'Min dose (mL/L)'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _maxControllers[product],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _tr('Dose max (mL/L)', 'Max dose (mL/L)'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _rodPitchControllers[product],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _tr('Pas de tige filetee (mm/tour)', 'Threaded rod pitch (mm/turn)'),
                hintText: _tr('Ex: 2', 'Eg: 2'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _stepsPerTurnControllers[product],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _tr('Pas moteur par tour', 'Steps per turn'),
                      hintText: _tr('Ex: 200', 'Eg: 200'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _mlPerMmControllers[product],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _tr('mL par mm', 'mL per mm'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            _buildProductPlanSummary(product),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('Dosage des produits', 'Products dosing')),
        backgroundColor: Colors.green,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _tr(
                  'Saisissez les valeurs de dosage pour les produits A, B, C.',
                  'Enter dosing values for products A, B, C.',
                ),
                style: TextStyle(
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _tr(
                  'Parametres mecaniques requis: pas de tige, pas moteur/tour et mL/mm.',
                  'Mechanical parameters required: rod pitch, steps/turn and mL/mm.',
                ),
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tankCapacityController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: _tr('Capacite de la citerne (L)', 'Tank capacity (L)'),
                  hintText: _tr('Ex: 3000', 'Eg: 3000'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _buildGlobalPlanSummary(),
              _buildProductCard('A'),
              _buildProductCard('B'),
              _buildProductCard('C'),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_tr('Enregistrer', 'Save')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoneCommandSelectionScreen extends StatefulWidget {
  const _ZoneCommandSelectionScreen({
    this.isEditMode = false,
    this.isEnglish = false,
    this.initialName,
    this.initialUseValveControl = true,
    this.initialUseHumiditySensor = true,
    this.initialUseGasSensor = true,
    this.initialUseLightSensor = true,
    this.initialUseTemperatureSensor = true,
  });

  final bool isEditMode;
  final bool isEnglish;
  final String? initialName;
  final bool initialUseValveControl;
  final bool initialUseHumiditySensor;
  final bool initialUseGasSensor;
  final bool initialUseLightSensor;
  final bool initialUseTemperatureSensor;

  @override
  State<_ZoneCommandSelectionScreen> createState() =>
      _ZoneCommandSelectionScreenState();
}

class _ZoneCommandSelectionScreenState extends State<_ZoneCommandSelectionScreen> {
  final TextEditingController _nameController = TextEditingController();
  bool _useValveControl = true;
  bool _useHumiditySensor = true;
  bool _useGasSensor = true;
  bool _useLightSensor = true;
  bool _useTemperatureSensor = true;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName ?? '';
    _useValveControl = widget.initialUseValveControl;
    _useHumiditySensor = widget.initialUseHumiditySensor;
    _useGasSensor = widget.initialUseGasSensor;
    _useLightSensor = widget.initialUseLightSensor;
    _useTemperatureSensor = widget.initialUseTemperatureSensor;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _tr(String fr, String en) => widget.isEnglish ? en : fr;

  void _submit() {
    final zoneName = _nameController.text.trim();
    if (!widget.isEditMode && zoneName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Veuillez saisir le nom de la zone', 'Please enter the zone name'))),
      );
      return;
    }

    if (!(_useHumiditySensor || _useGasSensor || _useLightSensor || _useTemperatureSensor)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('Selectionnez au moins un capteur pour la zone', 'Select at least one sensor for this zone'))),
      );
      return;
    }

    Navigator.pop(context, {
      if (!widget.isEditMode) 'name': zoneName,
      'useValveControl': _useValveControl,
      'useHumiditySensor': _useHumiditySensor,
      'useGasSensor': _useGasSensor,
      'useLightSensor': _useLightSensor,
      'useTemperatureSensor': _useTemperatureSensor,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditMode
            ? _tr('Modifier capteurs', 'Edit sensors')
            : _tr('Nouvelle zone', 'New zone')),
        backgroundColor: Colors.green,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _tr('Configurer les commandes modifiables', 'Configure editable controls'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              if (!widget.isEditMode)
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: _tr('Nom de la zone', 'Zone name'),
                    hintText: _tr('Ex : Tomate', 'Ex: Tomato'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              if (!widget.isEditMode) const SizedBox(height: 16),
              SwitchListTile(
                value: _useValveControl,
                onChanged: (value) {
                  setState(() {
                    _useValveControl = value;
                  });
                },
                title: Text(_tr('Utiliser l electrovanne', 'Use electrovalve')),
                subtitle: Text(_tr('Activer la commande d ouverture/fermeture pour cette zone', 'Enable open/close command for this zone')),
              ),
              Text(
                _tr('Selectionner les capteurs utilises par cette zone', 'Select sensors used by this zone'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _useHumiditySensor,
                onChanged: (value) {
                  setState(() {
                    _useHumiditySensor = value;
                  });
                },
                title: Text(_tr('Capteur humidite', 'Humidity sensor')),
                subtitle: Text(_tr('Utiliser la mesure humidite pour cette zone', 'Use humidity measurement for this zone')),
              ),
              SwitchListTile(
                value: _useGasSensor,
                onChanged: (value) {
                  setState(() {
                    _useGasSensor = value;
                  });
                },
                title: Text(_tr('Capteur gaz', 'Gas sensor')),
                subtitle: Text(_tr('Utiliser la mesure gaz pour cette zone', 'Use gas measurement for this zone')),
              ),
              SwitchListTile(
                value: _useLightSensor,
                onChanged: (value) {
                  setState(() {
                    _useLightSensor = value;
                  });
                },
                title: Text(_tr('Capteur lumiere', 'Light sensor')),
                subtitle: Text(_tr('Utiliser la mesure lumiere pour cette zone', 'Use light measurement for this zone')),
              ),
              SwitchListTile(
                value: _useTemperatureSensor,
                onChanged: (value) {
                  setState(() {
                    _useTemperatureSensor = value;
                  });
                },
                title: Text(_tr('Capteur temperature', 'Temperature sensor')),
                subtitle: Text(_tr('Utiliser la mesure temperature pour cette zone', 'Use temperature measurement for this zone')),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_tr('Annuler', 'Cancel')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      child: Text(widget.isEditMode
                          ? _tr('Enregistrer', 'Save')
                          : _tr('Creer la zone', 'Create zone')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
