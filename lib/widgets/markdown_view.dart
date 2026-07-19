import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown 渲染组件：在 MarkdownBody 基础上增强代码块与表格体验。
///
/// - 代码块（pre）：深色圆角卡片 + 等宽字体 + 右上角复制按钮；
/// - 表格（table）：手动铺开单元格并包一层横向滚动，防止超宽破版。
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.data});

  /// 要渲染的 Markdown 文本。
  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodyMedium,
      ),
      builders: <String, MarkdownElementBuilder>{
        'pre': _PreBuilder(theme.colorScheme),
        'table': _TableBuilder(theme),
      },
    );
  }
}

/// 代码块渲染：深色圆角容器 + 等宽字体 + 右上角复制按钮。
class _PreBuilder extends MarkdownElementBuilder {
  _PreBuilder(this._colors);

  final ColorScheme _colors;

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // pre 的纯文本内容（去掉末尾换行，避免代码块底部多一行空白）
    final code = element.textContent.replaceAll(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: _colors.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 34, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                  color: _colors.inversePrimary,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 2,
            child: Builder(
              builder: (context) => IconButton(
                icon: Icon(Icons.copy, size: 15, color: _colors.inversePrimary),
                tooltip: '复制代码',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('代码已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 表格渲染：从 markdown 的 table 元素手动铺开单元格，包横向滚动。
class _TableBuilder extends MarkdownElementBuilder {
  _TableBuilder(this._theme);

  final ThemeData _theme;

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final rows = <TableRow>[];
    // 结构：table > thead/tbody > tr > th/td
    for (final section in element.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      final isHeader = section.tag == 'thead';
      for (final rowNode in section.children ?? const <md.Node>[]) {
        if (rowNode is! md.Element || rowNode.tag != 'tr') continue;
        final cells = <Widget>[];
        for (final cellNode in rowNode.children ?? const <md.Node>[]) {
          if (cellNode is! md.Element) continue;
          cells.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              cellNode.textContent,
              style: _theme.textTheme.bodySmall?.copyWith(
                fontWeight: isHeader ? FontWeight.bold : null,
              ),
            ),
          ));
        }
        if (cells.isNotEmpty) rows.add(TableRow(children: cells));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(
            color: _theme.colorScheme.outlineVariant,
            width: 0.5,
          ),
          children: rows,
        ),
      ),
    );
  }
}
