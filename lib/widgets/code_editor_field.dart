// 轻量 JS 代码编辑器字段：对标 Legado CodeEditActivity 的基础能力。
//
// 采用经典的「高亮层 + 透明输入层」叠加方案：上层 RichText 只读负责对输入
// 内容做轻量 JS 语法高亮（关键字/字符串/注释/数字），下层 TextField 透明文字
// 负责编辑与光标，两层共用同一字体/字号/行高与内边距，保证文字逐像素对齐。
// 支持行号显示（右侧编辑文本前的 gutter）。
import 'package:flutter/material.dart';

/// 对 JS 代码做轻量语法高亮，返回 RichText 的 TextSpan。
///
/// 覆盖：行注释 `//`、块注释 `/* */`、单双/模板字符串、关键字、数字；
/// 其余内容保持默认前景色。识别失败时按普通文本返回，不抛错。
TextSpan highlightJsCode(String code, {TextStyle? baseStyle}) {
  const keywords = {
    'var', 'let', 'const', 'function', 'return', 'if', 'else', 'for',
    'while', 'do', 'break', 'continue', 'switch', 'case', 'default',
    'new', 'class', 'extends', 'super', 'this', 'typeof', 'instanceof',
    'in', 'of', 'try', 'catch', 'finally', 'throw', 'async', 'await',
    'yield', 'delete', 'void', 'null', 'undefined', 'true', 'false',
    'import', 'export', 'from', 'require', 'module',
  };
  const keywordColor = Color(0xFF9C27B0);
  const stringColor = Color(0xFF2E7D32);
  const commentColor = Color(0xFF78909C);
  const numberColor = Color(0xFF1565C0);
  final palette = _Palette(keywords, keywordColor, stringColor, commentColor, numberColor);
  return TextSpan(
    style: baseStyle,
    children: _highlight(code, 0, code.length, palette),
  );
}

class _Palette {
  const _Palette(
    this.keywords,
    this.keywordColor,
    this.stringColor,
    this.commentColor,
    this.numberColor,
  );
  final Set<String> keywords;
  final Color keywordColor;
  final Color stringColor;
  final Color commentColor;
  final Color numberColor;
}

List<InlineSpan> _highlight(String code, int start, int end, _Palette p) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString()));
    buffer.clear();
  }

  var index = start;
  while (index < end) {
    final ch = code[index];
    // 行注释
    if (ch == '/' && code.startsWith('//', index)) {
      flush();
      var lineEnd = code.indexOf('\n', index);
      if (lineEnd < 0 || lineEnd > end) lineEnd = end;
      spans.add(TextSpan(text: code.substring(index, lineEnd), style: TextStyle(color: p.commentColor)));
      index = lineEnd;
      continue;
    }
    // 块注释
    if (ch == '/' && code.startsWith('/*', index)) {
      flush();
      var close = code.indexOf('*/', index + 2);
      if (close < 0 || close + 2 > end) close = end - 2;
      spans.add(TextSpan(text: code.substring(index, close + 2), style: TextStyle(color: p.commentColor)));
      index = close + 2;
      continue;
    }
    // 字符串
    if (ch == '"' || ch == "'" || ch == '`') {
      flush();
      var cursor = index + 1;
      while (cursor < end && code[cursor] != ch) {
        if (code[cursor] == '\\') cursor++;
        cursor++;
      }
      if (cursor >= end) cursor = end;
      spans.add(
        TextSpan(
          text: code.substring(index, cursor < end ? cursor + 1 : end),
          style: TextStyle(color: p.stringColor),
        ),
      );
      index = cursor < end ? cursor + 1 : end;
      continue;
    }
    // 数字
    if (_isDigit(ch) || (ch == '.' && index + 1 < end && _isDigit(code[index + 1]))) {
      buffer.write(ch);
      index++;
      while (index < end &&
          (_isDigit(code[index]) ||
              code[index] == '.' ||
              code[index] == 'x' ||
              code[index] == 'X' ||
              _isHex(code.codeUnitAt(index)))) {
        buffer.write(code[index]);
        index++;
      }
      final value = buffer.toString();
      buffer.clear();
      spans.add(TextSpan(text: value, style: TextStyle(color: p.numberColor)));
      continue;
    }
    // 标识符/关键字
    if (_isIdentStart(ch)) {
      final identStart = index;
      index++;
      while (index < end && _isIdentPart(code[index])) {
        index++;
      }
      final word = code.substring(identStart, index);
      if (p.keywords.contains(word)) {
        flush();
        spans.add(TextSpan(text: word, style: TextStyle(color: p.keywordColor, fontWeight: FontWeight.w700)));
      } else {
        buffer.write(word);
      }
      continue;
    }
    buffer.write(ch);
    index++;
  }
  flush();
  return spans;
}

bool _isDigit(String ch) => ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;
bool _isHex(int codeUnit) =>
    (codeUnit >= 0x61 && codeUnit <= 0x66) ||
    (codeUnit >= 0x41 && codeUnit <= 0x46);
bool _isIdentStart(String ch) {
  final u = ch.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || ch == '_' || ch == r'$' || u > 0x7F;
}
bool _isIdentPart(String ch) => _isIdentStart(ch) || _isDigit(ch);

/// JS 代码编辑器字段：行号 gutter + 语法高亮输入。
class JsCodeField extends StatefulWidget {
  const JsCodeField({
    super.key,
    required this.controller,
    this.onChanged,
    this.focusNode,
    this.minLines = 6,
    this.maxLines = 24,
    this.showLineNumbers = true,
    this.enabled = true,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final int minLines;
  final int maxLines;
  final bool showLineNumbers;
  final bool enabled;

  static const TextStyle codeStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.5,
    letterSpacing: 0.2,
  );

  @override
  State<JsCodeField> createState() => _JsCodeFieldState();
}

class _JsCodeFieldState extends State<JsCodeField> {
  // 高亮层与行号层跟随输入内容同步滚动：输入层关闭滚动、由外层容器滚动，
  // 两层高度与 TextField 一致，天然对齐，无需共享 ScrollController。
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = JsCodeField.codeStyle;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showLineNumbers)
            Container(
              width: 42,
              padding: const EdgeInsets.only(top: 10, bottom: 10),
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) {
                  final lineCount = '\n'.allMatches(value.text).length + 1;
                  return Text(
                    List.generate(lineCount, (i) => '  ${i + 1}').join('\n'),
                    style: style.copyWith(color: scheme.outline),
                  );
                },
              ),
            ),
          Expanded(
            child: Stack(
              textDirection: TextDirection.ltr,
              children: [
                // 高亮层：只读展示带语法高亮的文本（透明文字）。
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: widget.controller,
                        builder: (context, value, _) => SizedBox(
                          width: double.infinity,
                          child: Text.rich(
                            highlightJsCode(
                              value.text,
                              baseStyle: style.copyWith(color: Colors.transparent),
                            ),
                            softWrap: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 输入层：透明文字 + 可见光标。
                DefaultSelectionStyle(
                  selectionColor: scheme.primary.withValues(alpha: 0.25),
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    onChanged: widget.onChanged,
                    enabled: widget.enabled,
                    minLines: widget.minLines,
                    maxLines: widget.maxLines,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(10),
                    ),
                    style: style.copyWith(color: Colors.transparent),
                    cursorColor: scheme.primary,
                    keyboardType: TextInputType.multiline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏 JS 代码编辑页：对标 Legado JsSourceEditActivity / CodeEditActivity。
///
/// 提供语法高亮编辑、行号、URL 变量快捷插入与保存。返回值通过
/// `Navigator.pop<String>` 返回编辑后的代码。
class JsCodeEditPage extends StatefulWidget {
  const JsCodeEditPage({
    super.key,
    this.title = 'JS 代码编辑',
    this.initialCode = '',
    this.variableGroups = const [],
  });

  final String title;
  final String initialCode;
  final List<JsVariableGroup> variableGroups;

  @override
  State<JsCodeEditPage> createState() => _JsCodeEditPageState();
}

/// 变量分组（在代码编辑页插入 {{变量}} / @js: 等片段）。
class JsVariableGroup {
  const JsVariableGroup(this.title, this.items);

  final String title;
  final List<JsVariableItem> items;
}

class JsVariableItem {
  const JsVariableItem(this.label, this.insertText, [this.description]);

  final String label;
  final String insertText;
  final String? description;
}

/// 常用 Legado 书源变量分组（书源编辑/JS 编辑共用）。
const List<JsVariableGroup> kLegadoSourceVariableGroups = [
  JsVariableGroup('搜索变量', [
    JsVariableItem('搜索词', '{{key}}', '搜索关键字（自动半角化）'),
    JsVariableItem('页码', '{{page}}', '搜索/发现页码'),
  ]),
  JsVariableGroup('URL/规则变量', [
    JsVariableItem('基础地址', '{{baseUrl}}', '当前书源根地址'),
    JsVariableItem('章节URL', '{{chapterUrl}}', '正文请求地址'),
    JsVariableItem('来源URL', '{{sourceUrl}}', '目录/详情页地址'),
  ]),
  JsVariableGroup('存储变量', [
    JsVariableItem('写入变量', '@put:{name:value}', '保存到书源变量空间'),
    JsVariableItem('读取变量', '@get:{name}', '读取已存变量'),
  ]),
  JsVariableGroup('JS 片段', [
    JsVariableItem('JS 规则', '@js:', '执行 JS 规则并返回结果'),
    JsVariableItem('JS 块', '<js>...</js>', '内嵌 JS 代码块'),
    JsVariableItem('JS 变量读取', "@js:finalResult = source.get('k')", '读取 source.put 变量'),
    JsVariableItem('JS 变量写入', "@js:source.put('k', value)", '写入 source 变量'),
  ]),
  JsVariableGroup('请求体', [
    JsVariableItem('请求体变量', '{{form}}', '表单键值对 JSON'),
  ]),
];

class _JsCodeEditPageState extends State<JsCodeEditPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialCode);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _insertAtCursor(String text) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final updated = value.text.replaceRange(start, selection.isValid ? selection.end : start, text);
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    setState(() {});
  }

  void _showVariables() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          shrinkWrap: true,
          children: [
            for (final group in widget.variableGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Text(
                  group.title,
                  style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(sheetContext).colorScheme.primary,
                  ),
                ),
              ),
              for (final item in group.items)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add_rounded, size: 20),
                  title: Text(item.label),
                  subtitle: item.description == null
                      ? null
                      : Text(item.description!),
                  trailing: Text(
                    item.insertText,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _insertAtCursor(item.insertText);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '插入变量',
            onPressed: _showVariables,
            icon: const Icon(Icons.data_object_rounded),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _controller.text),
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: JsCodeField(
            controller: _controller,
            minLines: 12,
            maxLines: 200,
          ),
        ),
      ),
    );
  }
}

/// 弹出 JS 代码编辑页，返回编辑结果（取消返回 null）。
Future<String?> showJsCodeEditor({
  required BuildContext context,
  String title = 'JS 代码编辑',
  String initialCode = '',
  List<JsVariableGroup> variableGroups = kLegadoSourceVariableGroups,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => JsCodeEditPage(
        title: title,
        initialCode: initialCode,
        variableGroups: variableGroups,
      ),
    ),
  );
}