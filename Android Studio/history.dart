import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

enum HistoryMode { actions, periodic, mixed }

class HistoryScreen extends StatefulWidget {
  final String token;
  final bool isEnglish;

  const HistoryScreen({
    super.key,
    required this.token,
    this.isEnglish = false,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final List<Map<String, dynamic>> _history = [];
  final Set<String> _seenKeys = <String>{};

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _zoneController = TextEditingController();

  int _currentPage = 1;
  bool _isLoading = false;
  bool _hasMore = true;
  String? _errorMessage;
  Timer? _debounce;
  Timer? _autoRefreshTimer;
  Timer? _realtimeRefreshDebounce;
  io.Socket? _socket;

  HistoryMode _mode = HistoryMode.actions;

  DateTime? _dateFrom;
  DateTime? _dateTo;
  bool _includeAlerts = true;
  late bool _isEnglish;

  final String baseUrl =
      "https://bug-free-doodle-x57rv64rpp67cvrq5-8080.app.github.dev";

  String _tr(String fr, String en) => _isEnglish ? en : fr;

  @override
  void initState() {
    super.initState();
    _isEnglish = widget.isEnglish;
    _loadHistory(reset: true);
    _connectHistoryRealtime();

    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 200) {
        _loadHistory();
      }
    });

    _searchController.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        _loadHistory(reset: true);
      });
    });

    _restartAutoRefreshTimer();
  }

  Future<void> _showLanguageDialog() async {
    final selected = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_tr('Choisir la langue', 'Choose language')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool>(
              value: false,
              groupValue: _isEnglish,
              title: const Text('Français'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
            RadioListTile<bool>(
              value: true,
              groupValue: _isEnglish,
              title: const Text('English'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
      ),
    );

    if (selected == null || selected == _isEnglish || !mounted) return;
    setState(() {
      _isEnglish = selected;
    });
  }

  void _connectHistoryRealtime() {
    _socket?.dispose();

    _socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': widget.token})
          .enableReconnection()
          .build(),
    );

    _socket!.on('history-realtime', (_) {
      // Debounce bursty server events so we do only one API refresh.
      _realtimeRefreshDebounce?.cancel();
      _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 350), () {
        if (!mounted || _isLoading) return;
        _loadHistory(reset: true);
      });
    });
  }

  void _restartAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();

    const interval = Duration(seconds: 30);

    _autoRefreshTimer = Timer.periodic(interval, (_) {
      if (!_isLoading) {
        _loadHistory(reset: true);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _autoRefreshTimer?.cancel();
    _realtimeRefreshDebounce?.cancel();
    _socket?.dispose();
    _searchController.dispose();
    _zoneController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _modeLabel(HistoryMode mode) {
    switch (mode) {
      case HistoryMode.actions:
        return _tr("Historique des actions", "Action history");
      case HistoryMode.periodic:
        return _tr("Valeurs capteurs", "Sensor values");
      case HistoryMode.mixed:
        return _tr("Historique mixte", "Mixed history");
    }
  }

  String _itemKey(Map<String, dynamic> item) {
    final id = (item["id"] ?? "").toString();
    final zoneId = (item["zone_id"] ?? "").toString();
    final created = (item["created_at"] ?? item["timestamp"] ?? item["datetime"] ?? "")
        .toString();

    final historyType = (item["history_type"] ?? "").toString().toUpperCase();
    final isMeasurement = historyType == "PERIODIC" || historyType == "MEASUREMENT";

    if (isMeasurement) {
      return "MEASUREMENT|$id|$zoneId|$created";
    }

    final eventType = (item["event_type"] ?? item["type"] ?? "EVENT").toString();
    final message = (item["message"] ?? item["alert_message"] ?? "").toString();
    return "EVENT|$id|$zoneId|$created|$eventType|$message";
  }

  DateTime? _parseServerDate(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;

    if (s.contains(' ') && !s.contains('T')) {
      final asIsoUtc = '${s.replaceFirst(' ', 'T')}Z';
      return DateTime.tryParse(asIsoUtc);
    }

    return DateTime.tryParse(s);
  }

  String _formatDate(String? raw) {
    final parsed = _parseServerDate(raw);
    if (parsed == null) return (raw == null || raw.isEmpty) ? "--" : raw;

    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');

    return "${two(local.day)}/${two(local.month)}/${local.year} "
        "${two(local.hour)}:${two(local.minute)}";
  }

  Future<void> _loadHistory({bool reset = false}) async {
    if (_isLoading) return;
    if (!reset && !_hasMore) return;

    if (reset) {
      _currentPage = 1;
      _hasMore = true;
      _history.clear();
      _seenKeys.clear();
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    const int limit = 20;

    try {
      final zoneText = _zoneController.text.trim();
      final int? zoneId = zoneText.isEmpty ? null : int.tryParse(zoneText);

      if (zoneText.isNotEmpty && zoneId == null) {
        throw Exception(_tr("Zone invalide: '$zoneText'", "Invalid zone: '$zoneText'"));
      }

      final offset = (_currentPage - 1) * limit;

      const endpoint = "/history";

      final queryParams = {
        "mode": _mode == HistoryMode.periodic
            ? "periodic"
            : _mode == HistoryMode.mixed
                ? "mixed"
                : "events",
        "limit": "$limit",
        "offset": "$offset",
        "include_alerts": _includeAlerts ? "1" : "0",
        if (_searchController.text.trim().isNotEmpty)
          "q": _searchController.text.trim(),
        if (zoneId != null) "zone_id": "$zoneId",
        if (_dateFrom != null) "date_from": _dateFrom!.toIso8601String(),
        if (_dateTo != null) "date_to": _dateTo!.toIso8601String(),
      };

      final uri = Uri.parse("$baseUrl$endpoint").replace(
        queryParameters: queryParams,
      );

      final response = await http
          .get(
        uri,
        headers: {
          "Accept": "application/json",
          "Authorization": "Bearer ${widget.token}",
        },
      )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 401) {
        throw Exception(_tr("Session expirée ou token invalide. Reconnectez-vous.", "Session expired or invalid token. Please log in again."));
      }

      if (response.statusCode != 200) {
        throw Exception("HTTP ${response.statusCode}: ${response.body}");
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw Exception(_tr("Réponse JSON invalide", "Invalid JSON response"));
      }

      final rawItemsDynamic = decoded["items"];
      final rawItems = (rawItemsDynamic is List) ? rawItemsDynamic : const [];

      final data = rawItems
          .whereType<Map>()
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .map<Map<String, dynamic>>((item) {
        final historyType = (item["history_type"] ?? "").toString().toUpperCase();
        final isMeasurement = historyType == "PERIODIC" ||
            (_mode == HistoryMode.periodic && historyType.isEmpty);

        final alertObj = item["alert"];
        if (alertObj is Map) {
          item["alert_message"] = (alertObj["message"] ?? "").toString();
          item["alert_level"] = (alertObj["level"] ?? "WARNING").toString();
          item["alert_source"] = _normalizeActionSource(alertObj["source"]);
        } else if ((item["alert_message"] ?? "").toString().trim().isEmpty) {
          item["alert_message"] = (item["active_alert_message"] ?? "").toString();
          item["alert_level"] = (item["active_alert_level"] ?? "WARNING").toString();
          item["alert_source"] = _normalizeActionSource(item["active_alert_source"]);
        }

        if (isMeasurement) {
          final gaz = item["gaz"] ?? item["gas"] ?? item["nutrition"] ?? 0;
          item["gaz"] = gaz;
          item["nutrition"] = gaz;
          item["history_type"] = "MEASUREMENT";
        } else {
          item["history_type"] = "EVENT";
          item["event_type"] =
              (item["event_type"] ?? item["event_kind"] ?? item["type"] ?? "EVENT")
                  .toString();
          item["message"] = (item["message"] ?? item["alert_message"] ?? "-").toString();
          item["source"] = _normalizeActionSource(
            item["source"] ?? item["alert_source"] ?? "MOBILE",
          );
          item["level"] = (item["level"] ?? item["alert_level"] ?? "INFO").toString();
        }
        return item;
      })
          .where((item) {
        final k = _itemKey(item);
        if (_seenKeys.contains(k)) return false;
        _seenKeys.add(k);
        return true;
      }).toList();

      bool nextHasMore = data.length == limit;
      final pagination = decoded["pagination"];
      if (pagination is Map) {
        final p = Map<String, dynamic>.from(pagination);
        if (p["hasMore"] is bool) nextHasMore = p["hasMore"] == true;
      }

      if (!mounted) return;
      setState(() {
        _history.addAll(data);
        _currentPage++;
        _hasMore = nextHasMore;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = _tr("Timeout: impossible de charger l'historique.", "Timeout: unable to load history.");
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    await _loadHistory(reset: true);
  }

  Color _alertColor(String level) {
    final l = level.toUpperCase();
    if (l == "CRITICAL" || l == "ERROR") return Colors.red;
    if (l == "WARNING") return Colors.orange;
    return Colors.blueGrey;
  }

  String _normalizeActionSource(dynamic rawSource) {
    final source = (rawSource ?? "").toString().trim().toUpperCase();
    if (source.contains("LABVIEW")) return "LABVIEW";
    if (source.contains("MOBILE") ||
        source.contains("FLUTTER") ||
        source.contains("APP") ||
        source.contains("CLIENT") ||
        source.contains("PHONE")) {
      return "MOBILE";
    }
    if (source.contains("SERVER") || source.contains("BACKEND")) {
      return "SERVER";
    }
    return "UNKNOWN";
  }

  Color _actionSourceColor(String source) {
    if (source == "LABVIEW") return Colors.indigo;
    if (source == "MOBILE") return Colors.green;
    if (source == "SERVER") return Colors.blueGrey;
    return Colors.grey;
  }

  String _sourceLabel(String source) {
    if (source == "LABVIEW") return "LabVIEW";
    if (source == "MOBILE") return _tr("Mobile", "Mobile");
    if (source == "SERVER") return _tr("Serveur", "Server");
    return _tr("Inconnu", "Unknown");
  }

  Widget _chip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        "$label: $value",
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  String _valveLabel(dynamic valve) {
    return _isValveOn(valve) ? _tr('Ouverte', 'Open') : _tr('Fermée', 'Closed');
  }

  String _irrigationModeLabel(dynamic mode) {
    return _isManualMode(mode) ? _tr('Manuel', 'Manual') : _tr('Auto', 'Auto');
  }

  bool _isValveOn(dynamic valve) {
    final value = (valve ?? '').toString().trim().toLowerCase();
    return valve == true ||
        valve == 1 ||
        value == '1' ||
        value == 'true' ||
        value == 'on' ||
        value == 'marche';
  }

  bool _isManualMode(dynamic mode) {
    if (mode is bool) return mode;
    if (mode is num) return mode != 0;
    final value = (mode ?? '').toString().trim().toUpperCase();
    return value == 'MANUAL' ||
        value == 'MANUEL' ||
        value == 'ON' ||
        value == 'TRUE' ||
        value == '1';
  }

  bool _isEnabled(dynamic value, {bool fallback = true}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final normalized = value.toString().trim().toLowerCase();
    if (['1', 'true', 'on', 'yes'].contains(normalized)) return true;
    if (['0', 'false', 'off', 'no'].contains(normalized)) return false;
    return fallback;
  }

  String _extractModeFromEvent(Map<String, dynamic> item) {
    final rawMode = (item['mode'] ?? item['ev_mode'] ?? '').toString().trim();
    if (rawMode.isNotEmpty) {
      return _irrigationModeLabel(rawMode);
    }

    final msg = (item['message'] ?? '').toString();
    final upperMsg = msg.toUpperCase();
    if (upperMsg.contains('MANUAL') || upperMsg.contains('MANUEL')) {
      return _tr('Manuel', 'Manual');
    }
    if (upperMsg.contains('AUTO')) {
      return _tr('Auto', 'Auto');
    }

    return '--';
  }

  String _normalizeForTranslation(String value) {
    return value
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[\s\t\n\r]+'), ' ')
        .replaceAll(RegExp(r'\s*:\s*'), ':')
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

  String _translateHistoryMessage(String raw) {
    final message = raw.trim();
    if (message.isEmpty) return message;

    String translateOneLine(String lineRaw) {
      final line = lineRaw.trim();
      if (line.isEmpty) return line;
      final n = _normalizeForTranslation(line);

      if (_isEnglish) {
        if (n.contains('rapid') && n.contains('evaporation')) return 'Risk of rapid evaporation';
        if ((n.contains('urgent') && n.contains('irrigation')) || n.contains('irrigation urgente')) {
          return 'Urgent irrigation needed';
        }
        if (n.contains('temperature') && (n.contains('eleve') || n.contains('high'))) {
          return 'Alert : High temperature';
        }
        if ((n.contains('gaz') || n.contains('gas')) && (n.contains('detect') || n.contains('detected'))) {
          return 'Alert: Gas detected';
        }
        if (n.contains('ouverture') && n.contains('vanne')) return 'Valve opened';
        if (n.contains('fermeture') && n.contains('vanne')) return 'Valve closed';
        if (n.contains('passage') && n.contains('mode manuel')) return 'Switched to manual mode';
        if (n.contains('passage') && n.contains('mode auto')) return 'Switched to auto mode';
        if (n.contains('modification') && n.contains('nom') && n.contains('zone')) return 'Zone name updated';
        if (n.contains('modification') && n.contains('seuil')) return 'Zone thresholds updated';
        if ((n.contains('configuration') && n.contains('capteur')) || n.contains('capteurs mise a jour')) {
          return 'Sensor configuration updated';
        }
        if ((n.contains('humidite') || n.contains('humidity')) && n.contains('bas')) return 'Low humidity alert';
        if ((n.contains('humidite') || n.contains('humidity')) && (n.contains('haut') || n.contains('high'))) return 'High humidity alert';
        if (n.contains('temperature') && n.contains('basse')) return 'Low temperature alert';
        if ((n.contains('gaz') || n.contains('gas')) && (n.contains('eleve') || n.contains('high'))) return 'High gas alert';
        if ((n.contains('lumiere') || n.contains('light')) && (n.contains('faible') || n.contains('low'))) return 'Low light alert';
        if ((n.contains('niveau') || n.contains('tank')) && n.contains('bas')) return 'Low tank level alert';

        return line
            .replaceAll(RegExp(r'ouverture de la vanne', caseSensitive: false), 'Valve opened')
            .replaceAll(RegExp(r'fermeture de la vanne', caseSensitive: false), 'Valve closed')
            .replaceAll(RegExp(r'passage en mode manuel', caseSensitive: false), 'Switched to manual mode')
            .replaceAll(RegExp(r'passage en mode auto', caseSensitive: false), 'Switched to auto mode')
            .replaceAll(RegExp(r'modification du nom de la zone', caseSensitive: false), 'Zone name updated')
            .replaceAll(RegExp(r'modification des seuils( de la zone)?', caseSensitive: false), 'Zone thresholds updated')
            .replaceAll(RegExp(r'modification de la configuration des capteurs', caseSensitive: false), 'Sensor configuration updated')
            .replaceAll(RegExp(r'configuration des capteurs mise a jour', caseSensitive: false), 'Sensor configuration updated')
            .replaceAll(RegExp(r'alerte\s*:\s*temperature\s*elev[ée]e', caseSensitive: false), 'Alert : High temperature')
            .replaceAll(RegExp(r'alerte\s*:\s*gaz\s*detect[ée]e', caseSensitive: false), 'Alert: Gas detected')
            .replaceAll(RegExp(r'risque evaporation rapide', caseSensitive: false), 'Risk of rapid evaporation')
            .replaceAll(RegExp(r'alerte\s*:\s*irrigation urgente', caseSensitive: false), 'Urgent irrigation needed');
      }

      if (n.contains('rapid') && n.contains('evaporation')) return 'Risque évaporation rapide';
      if ((n.contains('urgent') && n.contains('irrigation')) || n.contains('irrigation urgente')) {
        return 'Alerte : irrigation urgente';
      }
      if (n.contains('temperature') && (n.contains('eleve') || n.contains('high'))) {
        return 'Alerte : temperature elevée';
      }
      if ((n.contains('gaz') || n.contains('gas')) && (n.contains('detect') || n.contains('detected'))) {
        return 'Alerte : gaz detectée';
      }
      if ((n.contains('valve') && n.contains('open')) || (n.contains('ouverture') && n.contains('vanne'))) {
        return 'Ouverture de la vanne';
      }
      if ((n.contains('valve') && (n.contains('closed') || n.contains('close'))) ||
          (n.contains('fermeture') && n.contains('vanne'))) {
        return 'Fermeture de la vanne';
      }
      if ((n.contains('switched') && n.contains('manual')) || (n.contains('passage') && n.contains('mode manuel'))) {
        return 'Passage en mode manuel';
      }
      if ((n.contains('switched') && n.contains('auto')) || (n.contains('passage') && n.contains('mode auto'))) {
        return 'Passage en mode auto';
      }
      if ((n.contains('zone name updated')) || (n.contains('modification') && n.contains('nom') && n.contains('zone'))) {
        return 'Nom de zone mis a jour';
      }
      if ((n.contains('zone thresholds updated')) || (n.contains('modification') && n.contains('seuil'))) {
        return 'Seuils de zone mis a jour';
      }
      if (n.contains('sensor configuration updated') || (n.contains('configuration') && n.contains('capteur'))) {
        return 'Configuration des capteurs mise a jour';
      }

      return line
          .replaceAll(RegExp(r'valve opened', caseSensitive: false), 'Ouverture de la vanne')
          .replaceAll(RegExp(r'valve closed', caseSensitive: false), 'Fermeture de la vanne')
          .replaceAll(RegExp(r'switched to manual mode', caseSensitive: false), 'Passage en mode manuel')
          .replaceAll(RegExp(r'switched to auto mode', caseSensitive: false), 'Passage en mode auto')
          .replaceAll(RegExp(r'zone name updated', caseSensitive: false), 'Nom de zone mis a jour')
          .replaceAll(RegExp(r'zone thresholds updated', caseSensitive: false), 'Seuils de zone mis a jour')
          .replaceAll(RegExp(r'sensor configuration updated', caseSensitive: false), 'Configuration des capteurs mise a jour')
          .replaceAll(RegExp(r'low humidity alert', caseSensitive: false), 'Alerte : humidite basse')
          .replaceAll(RegExp(r'high humidity alert', caseSensitive: false), 'Alerte : humidite elevee')
          .replaceAll(RegExp(r'low temperature alert', caseSensitive: false), 'Alerte : temperature basse')
          .replaceAll(RegExp(r'high temperature alert', caseSensitive: false), 'Alerte : temperature elevée')
          .replaceAll(RegExp(r'high gas alert', caseSensitive: false), 'Alerte : gaz detectée')
          .replaceAll(RegExp(r'low light alert', caseSensitive: false), 'Alerte : lumiere faible')
          .replaceAll(RegExp(r'low tank level alert', caseSensitive: false), 'Alerte : niveau citerne bas')
          .replaceAll(RegExp(r'alert\s*:\s*high temperature', caseSensitive: false), 'Alerte : temperature elevée')
          .replaceAll(RegExp(r'alert\s*:\s*gas detected', caseSensitive: false), 'Alerte : gaz detectée')
          .replaceAll(RegExp(r'risk of rapid evaporation', caseSensitive: false), 'Risque évaporation rapide')
          .replaceAll(RegExp(r'urgent irrigation needed', caseSensitive: false), 'Alerte : irrigation urgente');
    }

    return message
        .split(RegExp(r'[\r\n]+'))
        .map(translateOneLine)
        .join('\n');
  }

  Widget _buildFilters() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.green.shade50, Colors.white],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        children: [
          // Row 1: Search + Zone ID + Filter Button
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 380;
              return Row(
                children: [
                  Expanded(
                    flex: isNarrow ? 2 : 3,
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        labelText: _tr("Recherche", "Search"),
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  SizedBox(width: isNarrow ? 6 : 10),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _zoneController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      textAlignVertical: TextAlignVertical.center,
                      decoration: InputDecoration(
                        labelText: _tr("Zone", "Zone"),
                        floatingLabelAlignment: FloatingLabelAlignment.center,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 8,
                        ),
                      ),
                      onSubmitted: (_) => _loadHistory(reset: true),
                    ),
                  ),
                  SizedBox(width: isNarrow ? 6 : 10),
                  Flexible(
                    child: ElevatedButton.icon(
                      onPressed: () => _loadHistory(reset: true),
                      icon: Icon(
                        Icons.filter_alt,
                        size: isNarrow ? 14 : 16,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: isNarrow ? 6 : 10,
                          vertical: 10,
                        ),
                        minimumSize: Size(0, isNarrow ? 42 : 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _tr("Filtrer", "Filter"),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: isNarrow ? 12 : 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // Row 2: Mode dropdown
          DropdownButtonFormField<HistoryMode>(
            value: _mode,
            decoration: InputDecoration(
              labelText: _tr("Mode historique", "History mode"),
              prefixIcon: const Icon(Icons.history),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            ),
            items: HistoryMode.values
                .map(
                  (m) => DropdownMenuItem<HistoryMode>(
                    value: m,
                    child: Text(_modeLabel(m)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _mode = value;
                if (_mode == HistoryMode.periodic) {
                  _includeAlerts = true;
                }
              });
              _restartAutoRefreshTimer();
              _loadHistory(reset: true);
            },
          ),
          const SizedBox(height: 8),
          Text(
            _mode == HistoryMode.actions
                ? _tr('Actions: seuils, nom, vanne, mode auto/manuel, configuration capteurs, avec alertes.', 'Actions: thresholds, name, valve, auto/manual mode, sensor configuration, with alerts.')
                : _mode == HistoryMode.periodic
                    ? _tr('Valeurs capteurs: snapshots périodiques (1 minute), avec alertes actives.', 'Sensor values: periodic snapshots (1 minute), with active alerts.')
                    : _tr('Mixte: regroupe actions + valeurs capteurs, avec alertes.', 'Mixed: combines actions + sensor values, with alerts.'),
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 12),

          // Row 3: Date filters
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _dateFrom ?? DateTime.now().subtract(const Duration(days: 30)),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setState(() => _dateFrom = picked);
                      _loadHistory(reset: true);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 20, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _dateFrom != null
                                ? "${_tr("Du", "From")} ${_dateFrom!.day}/${_dateFrom!.month}/${_dateFrom!.year}"
                                : _tr("Date début", "Start date"),
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _dateTo ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setState(() => _dateTo = picked);
                      _loadHistory(reset: true);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 20, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _dateTo != null
                                ? "${_tr("Au", "To")} ${_dateTo!.day}/${_dateTo!.month}/${_dateTo!.year}"
                                : _tr("Date fin", "End date"),
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_dateFrom != null || _dateTo != null)
                IconButton(
                  icon: const Icon(Icons.clear, color: Colors.red),
                  onPressed: () {
                    setState(() {
                      _dateFrom = null;
                      _dateTo = null;
                    });
                    _loadHistory(reset: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Row 4: Include alerts switch
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.notifications_active, color: Colors.orange.shade600),
                    const SizedBox(width: 10),
                    Text(
                      _tr("Inclure les alertes", "Include alerts"),
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                Switch(
                  value: _includeAlerts,
                  onChanged: (value) {
                    setState(() => _includeAlerts = value);
                    _loadHistory(reset: true);
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> item) {
    final zoneId = item["zone_id"] ?? "--";
    final zoneName = (item["zone_name"] ?? "Zone $zoneId").toString();
    final createdAt =
        _formatDate((item["created_at"] ?? item["timestamp"] ?? item["datetime"])?.toString());

    final historyType = (item["history_type"] ?? "").toString().toUpperCase();
    final isMeasurement = historyType == "PERIODIC" || historyType == "MEASUREMENT";

    if (isMeasurement) {
      final valve = item["valve"] ?? item["ev_state"] ?? false;
      final evMode = (item["mode"] ?? item["ev_mode"] ?? "AUTO").toString();
      final zoneTemperature = item["zone_temperature"] ?? item["temperature"] ?? 0;
      final globalTemperature = item["temperature"] ?? 0;
      final useHum = _isEnabled(item["use_hum"]);
      final useTemp = _isEnabled(item["use_temp"]);
      final useGaz = _isEnabled(item["use_gaz"]);
      final useLight = _isEnabled(item["use_light"]);
      final useEv = _isEnabled(item["use_ev"]);
      
      final alertMessage = (item["alert_message"] ?? "").toString().trim();
      final translatedAlertMessage = _translateHistoryMessage(alertMessage);
      final alertLevel = (item["alert_level"] ?? "INFO").toString();
      final hasAlert = alertMessage.isNotEmpty;
      final isCritical =
          alertLevel.toUpperCase() == "CRITICAL" || alertLevel.toUpperCase() == "ERROR";

      return Card(
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        elevation: hasAlert ? 6 : 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: hasAlert
              ? BorderSide(color: _alertColor(alertLevel), width: 1.2)
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    hasAlert
                        ? (isCritical ? Icons.error : Icons.warning_amber_rounded)
                        : Icons.schedule,
                    color: hasAlert ? _alertColor(alertLevel) : Colors.teal,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      zoneName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
                  Text(createdAt, style: const TextStyle(fontSize: 12)),
                ],
              ),
              if (hasAlert) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _alertColor(alertLevel).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(isCritical ? Icons.error : Icons.warning,
                          color: _alertColor(alertLevel)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "[$alertLevel] $translatedAlertMessage",
                          style: TextStyle(
                            color: _alertColor(alertLevel),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                _tr("Données globales", "Global data"),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _chip(_tr("Temp air", "Air temp"), "${globalTemperature}°C"),
                  _chip(_tr("Humidité air", "Air humidity"), "${item["humidity_air"] ?? 0}%"),
                  _chip(_tr("Niveau citerne", "Tank level"), "${item["water_level"] ?? 0}"),
                  _chip(_tr("pH citerne", "Tank pH"), "${item["water_ph"] ?? 0}"),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _tr("Données capteurs zone", "Zone sensor data"),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  if (useHum) _chip(_tr("Humidité zone", "Zone humidity"), "${item["humidity"] ?? 0}%"),
                  if (useTemp) _chip(_tr("Temp zone", "Zone temp"), "${zoneTemperature}°C"),
                  if (useGaz) _chip(_tr("Gaz", "Gas"), "${item["gaz"] ?? item["gas"] ?? 0} ppm"),
                  if (useLight) _chip(_tr("Lumière", "Light"), "${item["light"] ?? 0} lx"),
                  if (useEv) _chip(_tr("Vanne", "Valve"), _valveLabel(valve)),
                  if (useEv) _chip(_tr("Mode", "Mode"), _irrigationModeLabel(evMode)),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final eventType = (item["event_type"] ?? item["type"] ?? "EVENT").toString().toUpperCase();
    final message = _translateHistoryMessage((item["message"] ?? "-").toString());
    final level = (item["level"] ?? "INFO").toString();
    final source = _normalizeActionSource(item["source"]);
    final modeValue = _extractModeFromEvent(item);

    IconData eventIcon;
    Color eventColor;
    switch (eventType) {
      case 'ALERT':
        eventIcon = Icons.warning_amber_rounded;
        eventColor = _alertColor(level);
        break;
      case 'VALVE_CHANGE':
      case 'EV_CHANGE':
        eventIcon = Icons.water;
        eventColor = Colors.blue;
        break;
      case 'THRESHOLD_CHANGE':
        eventIcon = Icons.tune;
        eventColor = Colors.deepPurple;
        break;
      case 'NAME_CHANGE':
        eventIcon = Icons.edit;
        eventColor = Colors.brown;
        break;
      case 'MODE_CHANGE':
        eventIcon = Icons.sync_alt;
        eventColor = Colors.indigo;
        break;
      case 'SENSOR_CONFIG_CHANGE':
        eventIcon = Icons.tune;
        eventColor = Colors.deepPurple;
        break;
      default:
        eventIcon = Icons.timeline;
        eventColor = Colors.blueGrey;
    }

    String actionTypeLabel = '';
    switch (eventType) {
      case 'ALERT':
        actionTypeLabel = _tr('Alerte', 'Alert');
        break;
      case 'VALVE_CHANGE':
        actionTypeLabel = _tr('Vanne', 'Valve');
        break;
      case 'THRESHOLD_CHANGE':
        actionTypeLabel = _tr('Seuils', 'Thresholds');
        break;
      case 'NAME_CHANGE':
        actionTypeLabel = _tr('Nom', 'Name');
        break;
      case 'MODE_CHANGE':
        actionTypeLabel = _tr('Mode', 'Mode');
        break;
      case 'SENSOR_CONFIG_CHANGE':
        actionTypeLabel = _tr('Capteurs', 'Sensors');
        break;
      default:
        actionTypeLabel = eventType;
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: eventColor.withOpacity(0.6), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(eventIcon, color: eventColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zoneName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: eventColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          actionTypeLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: eventColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(createdAt, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _actionSourceColor(source).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _sourceLabel(source),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _actionSourceColor(source),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: eventColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: eventColor.withOpacity(0.9),
                ),
              ),
            ),
            if (eventType == 'ALERT')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _chip(_tr("Niveau", "Level"), level),
              ),
            if (eventType == 'MODE_CHANGE' && modeValue != '--')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _chip(_tr("Mode", "Mode"), modeValue),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showEmpty = _history.isEmpty && !_isLoading && _errorMessage == null;

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
                leading: const Icon(Icons.language),
                title: Text(_tr('Langue', 'Language')),
                subtitle: Text(_isEnglish ? 'English' : 'Français'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _showLanguageDialog();
                },
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        title: Text(
          _tr("Historique", "History"),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.green,
        elevation: 8,
        shadowColor: Colors.black.withOpacity(0.3),
        actions: [
          IconButton(
            onPressed: () => _loadHistory(reset: true),
            icon: const Icon(Icons.refresh),
            tooltip: _tr("Actualiser", "Refresh"),
          ),
          Builder(
            builder: (context) => IconButton(
              onPressed: () => Scaffold.of(context).openEndDrawer(),
              icon: const Icon(Icons.menu),
              tooltip: _tr('Menu', 'Menu'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(child: _buildFilters()),
            if (_errorMessage != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Center(
                    child: Text("${_tr("Erreur", "Error")}: $_errorMessage",
                        style: const TextStyle(color: Colors.red)),
                  ),
                ),
              ),
            if (showEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(_tr("Aucune donnée", "No data"))),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                      (context, index) {
                    if (index >= _history.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return _buildCard(_history[index]);
                  },
                  childCount: _history.length + (_isLoading ? 1 : 0),
                ),
              ),
            if (!_isLoading && !_hasMore && _history.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text(_tr("Fin de l'historique", "End of history"))),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
