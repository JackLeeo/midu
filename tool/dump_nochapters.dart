// dump noChapters 类失败源的 ruleToc / ruleBookInfo(init, tocUrl) / ruleContent，
// 离线判断哪些可由「源数据编辑」或「引擎选择器改进」修复为可读目录。
import 'dart:convert';
import 'dart:io';

void main() {
  final decoded = jsonDecode(File(r'D:\gz\完美书源.已修复.json').readAsStringSync());
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded as Map)['bookSourceList'] as List;
  final want = ['猪猪书网', '猪猪小说', '刺猬猫网', '随心看网', '全免漫画', '猫眼看书', '四零二零', '久久小说', '免费小说', '溜达小说', '追书神器', '图书迷网', '虫虫书屋', '一米小说', '品如漫画'];
  for (final s in list.cast<Map<String, dynamic>>()) {
    final name = '${s['bookSourceName'] ?? ''}';
    if (!want.any(name.contains)) continue;
    print('===== $name [${s['bookSourceUrl']}] enable=${s['exploreUrl'] == null ? '' : ''}' );
    final bi = s['ruleBookInfo'];
    if (bi is Map) {
      for (final k in ['init', 'tocUrl', 'nextTocUrl']) {
        final v = bi[k];
        if (v != null && v.toString().trim().isNotEmpty) print('ruleBookInfo.$k: ${_c(v)}');
      }
    }
    final search = s['ruleSearch'];
    print('searchUrl: ${_c(s['searchUrl'])}');
    if (search is Map) {
      for (final k in ['bookList', 'bookUrl', 'name', 'author']) {
        final v = search[k];
        if (v != null && v.toString().trim().isNotEmpty) print('ruleSearch.$k: ${_c(v)}');
      }
    }
    final toc = s['ruleToc'];
    if (toc is Map) {
      for (final k in ['chapterList', 'chapterUrl', 'chapterName', 'nextTocUrl']) {
        final v = toc[k];
        if (v != null && v.toString().trim().isNotEmpty) print('ruleToc.$k: ${_c(v)}');
      }
    } else {
      print('ruleToc: ${_c(toc)}');
    }
    print('');
  }
}

String _c(Object o) {
  final str = o is String ? o : jsonEncode(o);
  return str.length > 1200 ? '${str.substring(0, 1200)}...[${str.length}]' : str;
}