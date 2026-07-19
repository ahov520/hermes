import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// 全局应用状态：连接配置 + API 客户端。
class AppState extends ChangeNotifier {
  static const String _kBaseUrl = 'hermes_base_url';
  static const String _kApiKey = 'hermes_api_key';

  /// 新装默认指向部署时探测到的局域网地址，用户可在设置页修改。
  static const String defaultBaseUrl = 'http://192.168.2.159:8642';

  String baseUrl = defaultBaseUrl;
  String apiKey = '';
  bool loaded = false;

  HermesApi? _api;

  HermesApi? get api => _api;

  bool get configured => _api != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
    apiKey = prefs.getString(_kApiKey) ?? '';
    _rebuildApi();
    loaded = true;
    notifyListeners();
  }

  Future<void> save({required String baseUrl, required String apiKey}) async {
    var url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    this.baseUrl = url;
    this.apiKey = apiKey.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, this.baseUrl);
    await prefs.setString(_kApiKey, this.apiKey);
    _rebuildApi();
    notifyListeners();
  }

  void _rebuildApi() {
    _api = apiKey.isEmpty
        ? null
        : HermesApi(baseUrl: baseUrl, apiKey: apiKey);
  }
}
