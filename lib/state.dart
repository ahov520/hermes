import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'studio/api.dart';

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

/// 一套 Hermes Studio（8648）连接配置（地址 + 账号 + 登录 token）。
class StudioAccount {
  StudioAccount({
    required this.name,
    required this.baseUrl,
    this.username = '',
    this.password = '',
    this.token = '',
  });

  factory StudioAccount.fromJson(Map<String, dynamic> json) => StudioAccount(
        name: (json['name'] ?? '默认').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        password: (json['password'] ?? '').toString(),
        token: (json['token'] ?? '').toString(),
      );

  String name;
  String baseUrl;
  String username;
  String password;
  String token;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
        'token': token,
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
  static const String _kStudioAccounts = 'studio_accounts';
  static const String _kStudioActive = 'studio_active';

  /// 新装默认指向部署时探测到的局域网地址，用户可在设置页修改。
  static const String defaultBaseUrl = 'http://192.168.2.159:8642';

  /// Studio（hermes-web-ui）默认地址。
  static const String defaultStudioBaseUrl = 'http://192.168.2.159:8648';

  List<ConnectionProfile> profiles = <ConnectionProfile>[
    ConnectionProfile(name: '默认', baseUrl: defaultBaseUrl, apiKey: ''),
  ];
  int activeIndex = 0;
  bool loaded = false;

  HermesApi? _api;

  /// Studio 账号列表与当前激活项。
  List<StudioAccount> studioAccounts = <StudioAccount>[
    StudioAccount(name: '局域网', baseUrl: defaultStudioBaseUrl),
  ];
  int studioActiveIndex = 0;

  StudioApi? _studio;

  /// 默认主题种子色（teal），与 theme.dart 中 hermesSeedColors 首个一致。
  static const int defaultSeedColorValue = 0xFF00696B;

  ThemeMode _themeMode = ThemeMode.system;
  int _seedColorValue = defaultSeedColorValue;

  HermesApi? get api => _api;

  /// 当前 Studio 客户端（未登录也可用于登录调用）。
  StudioApi? get studio => _studio;

  /// Studio 是否已持有登录 token。
  bool get studioLoggedIn => _studio?.isAuthed ?? false;

  StudioAccount get activeStudioAccount => studioAccounts[studioActiveIndex];

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
    // Studio 账号
    final studioRaw = prefs.getString(_kStudioAccounts);
    if (studioRaw != null && studioRaw.isNotEmpty) {
      try {
        final list = (jsonDecode(studioRaw) as List)
            .whereType<Map<String, dynamic>>()
            .map(StudioAccount.fromJson)
            .toList();
        if (list.isNotEmpty) studioAccounts = list;
      } catch (_) {
        // 配置损坏则用默认
      }
      studioActiveIndex = prefs.getInt(_kStudioActive) ?? 0;
      if (studioActiveIndex < 0 || studioActiveIndex >= studioAccounts.length) {
        studioActiveIndex = 0;
      }
    }
    _rebuildApi();
    _rebuildStudio();
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

  // ------------------------------------------------------------------
  // Studio 账号
  // ------------------------------------------------------------------

  /// 保存当前激活 Studio 账号的地址/用户名/密码（不动 token）。
  Future<void> saveStudioAccount({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    final account = activeStudioAccount;
    final credsChanged =
        account.baseUrl != url || account.username != username.trim();
    account.baseUrl = url;
    account.username = username.trim();
    account.password = password;
    if (credsChanged) account.token = ''; // 换地址/换账号后旧 token 作废
    await _persistStudio();
    _rebuildStudio();
    notifyListeners();
  }

  /// 新增一套 Studio 配置并切换过去。
  Future<void> addStudioAccount({
    required String name,
    required String baseUrl,
    String username = '',
    String password = '',
  }) async {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    studioAccounts.add(StudioAccount(
      name: name.trim().isEmpty ? '配置 ${studioAccounts.length + 1}' : name.trim(),
      baseUrl: url,
      username: username.trim(),
      password: password,
    ));
    studioActiveIndex = studioAccounts.length - 1;
    await _persistStudio();
    _rebuildStudio();
    notifyListeners();
  }

  /// 删除一套 Studio 配置（至少保留一套）。
  Future<void> deleteStudioAccount(int index) async {
    if (studioAccounts.length <= 1 ||
        index < 0 ||
        index >= studioAccounts.length) {
      return;
    }
    studioAccounts.removeAt(index);
    if (studioActiveIndex >= studioAccounts.length) {
      studioActiveIndex = studioAccounts.length - 1;
    } else if (studioActiveIndex > index) {
      studioActiveIndex--;
    }
    await _persistStudio();
    _rebuildStudio();
    notifyListeners();
  }

  /// 切换激活的 Studio 配置。
  Future<void> selectStudioAccount(int index) async {
    if (index < 0 ||
        index >= studioAccounts.length ||
        index == studioActiveIndex) {
      return;
    }
    studioActiveIndex = index;
    await _persistStudio();
    _rebuildStudio();
    notifyListeners();
  }

  /// Studio 登录：成功后 token 落盘并通知。
  Future<Map<String, dynamic>> loginStudio({
    required String username,
    required String password,
  }) async {
    final client = _studio;
    if (client == null) {
      throw StudioApiException(-1, '无可用 Studio 配置');
    }
    final me = await client.login(username: username, password: password);
    activeStudioAccount.username = username.trim();
    activeStudioAccount.password = password;
    await _persistStudio();
    notifyListeners();
    return me;
  }

  /// Studio 退出登录（清 token，保留账号密码便于重登）。
  Future<void> logoutStudio() async {
    activeStudioAccount.token = '';
    await _persistStudio();
    _rebuildStudio();
    notifyListeners();
  }

  Future<void> _persistStudio() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kStudioAccounts,
      jsonEncode(studioAccounts.map((a) => a.toJson()).toList()),
    );
    await prefs.setInt(_kStudioActive, studioActiveIndex);
  }

  void _rebuildStudio() {
    final a = activeStudioAccount;
    _studio = StudioApi(
      baseUrl: a.baseUrl,
      username: a.username.isEmpty ? null : a.username,
      password: a.password.isEmpty ? null : a.password,
      token: a.token.isEmpty ? null : a.token,
      onToken: (t) {
        a.token = t;
        _persistStudio();
      },
    );
  }
}
