import 'package:flutter/material.dart';

/// 可选主题种子色（首个为默认 teal，与 AppState 默认值一致）。
const List<Color> hermesSeedColors = <Color>[
  Color(0xFF00696B), // teal（默认）
  Color(0xFF0061A4), // 蓝
  Color(0xFF4A4FC4), // 靛
  Color(0xFF8E24AA), // 紫
  Color(0xFF2E7D32), // 绿
  Color(0xFFC75200), // 橙
  Color(0xFFC2185B), // 粉
];

/// 基于种子色构建 Material 3 主题（亮色 / 暗色由 brightness 决定）。
ThemeData buildHermesTheme(Color seed, Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ),
  );
}

/// Hermes Studio「墨水风」主题：纸感背景 + 近黑/近白单色强调，
/// 小圆角、极淡阴影（对标 hermes-web-ui 的 ink 设计语言）。
ThemeData buildInkTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final ink = light ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0);
  final scheme = ColorScheme.fromSeed(
    seedColor: ink,
    brightness: brightness,
  ).copyWith(
    primary: ink,
    onPrimary: light ? Colors.white : const Color(0xFF1A1A1A),
    surface: light ? Colors.white : const Color(0xFF2A2A2A),
    onSurface: light ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
    surfaceContainerHighest:
        light ? const Color(0xFFF0EFEA) : const Color(0xFF3A3A3A),
    outline: light ? const Color(0xFFE0E0E0) : const Color(0xFF3A3A3A),
    error: const Color(0xFFC62828),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        light ? const Color(0xFFF7F7F4) : const Color(0xFF1A1A1A),
    cardTheme: CardThemeData(
      elevation: 0.6,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}
