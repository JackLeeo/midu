// 标点压缩：对标 Legado「标点压缩」显示选项。
//
// 纯 Dart、零依赖，作用于显式换行（'\n'）分隔的文本行。两类处理：
//   1. 行首压缩：若一行以闭式标点（。，、；：！？…）」』】等）开头，说明该行是
//      因书源/排版失误在标点前断行，把这段标点合并到上一行行尾（消除错误的
//      行首标点），后续内容仍接在新段。
//   2. 行尾压缩：若一行以开式标点（（「『“【〔〈《等）结尾，把该标点挪到下一
//      行行首，避免开引号悬在上一行末。
//
// 边界保护：
//   - 空行（段落分隔）两侧一律不合并，保证段落结构稳定；
//   - 只移动紧跟的标点串，不吞并正文文字。
const String readerLineStartClosurePunctuation =
    '。，、；：！？…）〕〉》」』”›】　';
const String readerLineEndOpeningPunctuation = '（「『“【〔〈《‹';

final Set<String> _lineStartClosures =
    readerLineStartClosurePunctuation.split('').toSet();
final Set<String> _lineEndOpeners =
    readerLineEndOpeningPunctuation.split('').toSet();

/// 对标点压缩后的文本。
///
/// [text] 以 '\n' 分隔段落/行；返回值保持原换行总数或更少（只会合并错误的
/// 断行，绝不新增换行），因此不会引入新的空白段。
String applyPunctuationCompression(String text) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    // 1) 行首闭式标点 → 并入上一行行尾。首行没有上一行，跳过以免吞掉
    //    章节开头的标点（Legado 对页首同样不压缩）。
    if (i > 0 && lines[i].isNotEmpty && lines[i - 1].isNotEmpty) {
      final startRun = _leadingClosureRun(lines[i]);
      if (startRun > 0) {
        lines[i - 1] = lines[i - 1] + lines[i].substring(0, startRun);
        lines[i] = lines[i].substring(startRun);
      }
    }
    // 2) 行尾开式标点 → 挪到下一行行首（含首行：开引号/开括号悬挂在行尾
    //    是常见排版错误，必须能挪走）。
    if (i + 1 < lines.length &&
        lines[i].isNotEmpty &&
        lines[i + 1].isNotEmpty) {
      final endRun = _trailingOpenerRun(lines[i]);
      if (endRun > 0) {
        final moved = lines[i].substring(lines[i].length - endRun);
        lines[i] = lines[i].substring(0, lines[i].length - endRun);
        lines[i + 1] = moved + lines[i + 1];
      }
    }
  }
  return lines.join('\n');
}

/// 行首连续闭式标点的长度（仅统计紧跟开头的标点串）。
int _leadingClosureRun(String line) {
  var count = 0;
  for (var i = 0; i < line.length; i++) {
    if (!_lineStartClosures.contains(line[i])) break;
    count++;
  }
  return count;
}

/// 行尾连续开式标点的长度。
int _trailingOpenerRun(String line) {
  var count = 0;
  for (var i = line.length - 1; i >= 0; i--) {
    if (!_lineEndOpeners.contains(line[i])) break;
    count++;
  }
  return count;
}