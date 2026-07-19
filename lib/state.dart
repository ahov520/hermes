import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// 一套连接配置（服务器地址 + API Key）。
class ConnectionProfile {
  ConnectionProfile({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
  });

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      ConnectionProfile(
        name: (json['name'] ?? '默认').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        apiKey: (json['apiKey'] ?? '').toString(),
      );

  String name;
  String baseUrl;
  String apiKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
      };
}

/// 全局应用状态：多连接配置 + API 客户端。
class AppState extends ChangeNotifier {
  static const String _kBaseUrl = 'hermes_base_url'; // 旧版单配置 key（迁移用）
  static const String _kApiKey = 'hermes_api_key'; // 旧版单配置 key（迁移用）
  static const String _kProfiles = 'hermes_profiles';
  static const String _kActiveProfile = 'hermes_active_profile';
  static const String _kThemeMode = 'hermes_theme_mode';
  static const String _kSeedColor = 'hermes_seed_color';

  /// 新装默认指向部署时探测到的局域网地址，用户可在设置页修改。
  static const String defaultBaseUrl = 'http://192.168.2.159:8642';

  List<ConnectionProfile> profiles = <ConnectionProfile>[
    ConnectionProfile(name: '默认', baseUrl: defaultBaseUrl, apiKey: ''),
  ];
  int activeIndex = 0;
  bool loaded = false;

  HermesApi? _api;

  /// 默认主题种子色（teal），与 theme.dart 中 hermesSeedColors 首个一致。
  static const int defaultSeedColorValue = 0xFF00696B;

  ThemeMode _themeMode = ThemeMode.system;
  int _seedColorValue = defaultSeedColorValue;

  HermesApi? get api => _api;

  /// 当前主题模式（跟随系统 / 浅色 / 深色）。
  ThemeMode get themeMode => _themeMode;

  /// 当前主题种子色。
  Color get seedColor => Color(_seedColorValue);

  bool get configured => _api != null;

  ConnectionProfile get activeProfile => profiles[activeIndex];

  // 兼容旧调用点
  String get baseUrl => activeProfile.baseUrl;
  String get apiKey => activeProfile.apiKey;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .whereType<Map<String, dynamic>>()
            .map(ConnectionProfile.fromJson)
            .toList();
        if (list.isNotEmpty) profiles = list;
      } catch (_) {
        // 配置损坏则用默认
      }
      activeIndex = prefs.getInt(_kActiveProfile) ?? 0;
      if (activeIndex < 0 || activeIndex >= profiles.length) activeIndex = 0;
    } else {
      // 从旧版单配置迁移
      final oldUrl = prefs.getString(_kBaseUrl);
      final oldKey = prefs.getString(_kApiKey);
      if (oldUrl != null || oldKey != null) {
        profiles[0].baseUrl = oldUrl ?? defaultBaseUrl;
        profiles[0].apiKey = oldKey ?? '';
      }
    }
    // 外观设置
    final modeName = prefs.getString(_kThemeMode);
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => ThemeMode.system,
    );
    _seedColorValue = prefs.getInt(_kSeedColor) ?? defaultSeedColorValue;
    _rebuildApi();
    loaded = true;
    notifyListeners();
  }

  /// 保存当前编辑内容到指定配置（默认当前激活配置）。
  Future<void> save({required String baseUrl, required String apiKey}) async {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    activeProfile.baseUrl = url;
    activeProfile.apiKey = apiKey.trim();
    await _persist();
    _rebuildApi();
    notifyListeners();
  }

  /// 新增一套配置并切换过去。
  Future<void> addProfile({
    required String name,
    required String baseUrl,
    required String apiKey,
  }) async {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    profiles.add(ConnectionProfile(
      name: name.trim().isEmpty ? '配置 ${profiles.length + 1}' : name.trim(),
      baseUrl: url,
      apiKey: apiKey.trim(),
    ));
    activeIndex = profiles.length - 1;
    await _persist();
    _rebuildApi();
    notifyListeners();
  }

  /// 删除一套配置（至少保留一套）。
  Future<void> deleteProfile(int index) async {
    if (profiles.length <= 1 || index < 0 || index >= profiles.length) return;
    profiles.removeAt(index);
    if (activeIndex >= profiles.length) {
      activeIndex = profiles.length - 1;
    } else if (activeIndex > index) {
      activeIndex--;
    }
    await _persist();
    _rebuildApi();
    notifyListeners();
  }

  /// 切换激活配置。
  Future<void> selectProfile(int index) async {
    if (index < 0 || index >= profiles.length || index == activeIndex) return;
    activeIndex = index;
    await _persist();
    _rebuildApi();
    notifyListeners();
  }

  /// 设置主题模式并持久化。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode.name);
    notifyListeners();
  }

  /// 设置主题种子色并持久化。
  Future<void> setSeedColor(Color color) async {
    if (color.value == _seedColorValue) return;
    _seedColorValue = color.value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeedColor, _seedColorValue);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
    await prefs.setInt(_kActiveProfile, activeIndex);
  }

  void _rebuildApi() {
    final p = activeProfile;
    _api = p.apiKey.isEmpty
        ? null
        : HermesApi(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }
}
