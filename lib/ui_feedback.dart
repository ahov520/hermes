import 'package:flutter/material.dart';

/// 统一的错误提示：红底 SnackBar，可选带「重试」操作。
void showErrorSnack(BuildContext context, String message,
    {VoidCallback? onRetry}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: scheme.error,
      content: Text(message, style: TextStyle(color: scheme.onError)),
      action: onRetry == null
          ? null
          : SnackBarAction(
              label: '重试',
              textColor: scheme.onError,
              onPressed: onRetry,
            ),
    ),
  );
}

/// 连接状态圆点：null 灰（未知）、true 绿（在线）、false 红（离线）。
Widget buildConnectionDot(bool? online) {
  final color = switch (online) {
    true => Colors.green,
    false => Colors.red,
    null => Colors.grey,
  };
  return Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
