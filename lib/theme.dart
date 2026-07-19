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
