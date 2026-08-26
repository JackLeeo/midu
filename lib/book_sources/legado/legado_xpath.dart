import 'package:html/dom.dart' as dom;

/// 原生 XPath 子集评估器（对齐 Legado 书源 `@xpath:` / `//` 规则的常见用法）。
///
/// 不引入第三方 xpath 依赖，手写覆盖书源常用的 XPath 子集：
///   - 绝对路径 `//div[5]/div/div[3]/div[2]/ul/li`、`/html/body/div`；
///   - 相对路径（以标签名或 `*` 开头，从当前 context 求值）；
///   - 节点名测试（标签名大小写不敏感）、通配符 `*`；
///   - 位置谓词 `[N]`（1 基，按父级同标签分组计数）、`[last()]`、`[first()]`；
///   - 属性谓词 `[@attr]`、`[@attr="val"]`、`[@attr='val']`、`[contains(@attr,'s')]`；
///   - 文本谓词 `[text()="val"]`、`[.="val"]`、`[contains(.,'s')]`、`[normalize-space(.)="val"]`；
///   - 末段属性轴 `/@attr`（返回属性字符串）、文本轴末段 `text()`（返回直接文本）。
///
/// 中间步骤选中 `Element`，末段为 `/@attr` / `text()` 时返回 `String`。
class LegadoXPath {
  /// 对 [root]（Document 或 Element）求值 [xpath]，返回结果列表。
  static List<Object> evaluate(dom.Node root, String xpath) {
    final expr = xpath.trim();
    if (expr.isEmpty) return const [];

    final absolute = expr.startsWith('/');
    var descendant = false;
    var i = 0;
    if (expr.startsWith('//')) {
      descendant = true;
      i = 2;
    } else if (expr.startsWith('/')) {
      i = 1;
    }

    // 搜索根节点
    final List<dom.Node> seed;
    if (!absolute) {
      // 相对路径：从传入节点本身求子级
      seed = [root];
    } else {
      final doc = root is dom.Document ? root : root.parent;
      final docElem = doc is dom.Document ? doc.documentElement : (root is dom.Element ? root : null);
      seed = [docElem ?? root];
    }

    final steps = _splitSteps(expr.substring(i));
    if (steps.isEmpty) return const [];

    List<Object> current = seed;
    for (var si = 0; si < steps.length; si++) {
      final step = steps[si];
      final isDescendantFirst = si == 0 && descendant;
      current = _applyStep(current, step, isDescendantFirst);
      if (current.isEmpty) return const [];
    }

    // 终端结果转换
    final out = <Object>[];
    for (final node in current) {
      if (node is dom.Element) {
        out.add(node);
      } else if (node is dom.Text) {
        out.add(node.data);
      } else if (node is _AttrText) {
        out.add(node.value);
      }
    }
    return out;
  }

  /// 对当前节点集执行一步：返回子级（或首步后代）中匹配的节点。
  static List<Object> _applyStep(
    List<Object> current,
    String step,
    bool descendantAxis,
  ) {
    final trimmed = step.trim();
    if (trimmed.isEmpty) return current;

    // 末段属性轴 /@attr → 返回字符串节点占位（用父节点属性）
    if (trimmed.startsWith('@')) {
      final attr = trimmed.substring(1);
      final out = <Object>[];
      for (final node in current) {
        if (node is! dom.Element) continue;
        final v = node.attributes[attr];
        if (v != null && v.isNotEmpty) out.add(_AttrText(v));
      }
      return out;
    }

    // 末段 text()
    if (trimmed == 'text()') {
      final out = <Object>[];
      for (final node in current) {
        if (node is! dom.Element) continue;
        final t = node.nodes
            .whereType<dom.Text>()
            .map((t) => t.data)
            .join()
            .trim();
        if (t.isNotEmpty) out.add(_AttrText(t));
      }
      return out;
    }

    // 解析步骤本体与谓词 [..]
    final body = _stripPredicates(trimmed);
    final predicates = _extractPredicates(trimmed);

    final out = <Object>[];
    // 收集轴节点：非首步后代时仅当前节点自身子级；首步后代时含自身+全部后代
    for (final node in current) {
      if (node is! dom.Element) continue;
      List<dom.Node> axisNodes;
      if (descendantAxis) {
        axisNodes = [node, ..._descendants(node)];
      } else {
        axisNodes = [node];
      }
      for (final an in axisNodes) {
        if (an is! dom.Element) continue;
        var group = an.children.where((c) => _matchesNodeTest(c, body)).toList();
        group = _applyPredicates(group, predicates);
        // 聚合（按父级分组排序，保留文档顺序）
        out.addAll(group);
      }
    }
    return out;
  }

  static List<dom.Element> _descendants(dom.Element e) {
    final out = <dom.Element>[];
    void walk(dom.Element n) {
      for (final c in n.children) {
        out.add(c);
        walk(c);
      }
    }
    walk(e);
    return out;
  }

  static bool _matchesNodeTest(dom.Element e, String body) {
    if (body == '*' || body == 'node()') return true;
    final name = body.split(':').last.toLowerCase();
    return e.localName?.toLowerCase() == name;
  }

  static List<dom.Element> _applyPredicates(
    List<dom.Element> group,
    List<String> predicates,
  ) {
    var result = group;
    for (final raw in predicates) {
      final p = raw.trim();
      if (p.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(p)) {
        final idx = int.parse(p);
        result = idx >= 1 && idx <= result.length ? [result[idx - 1]] : const [];
        continue;
      }
      if (p == 'last()') {
        result = result.isNotEmpty ? [result.last] : const [];
        continue;
      }
      if (p == 'first()' || p == 'position()=1') {
        result = result.isNotEmpty ? [result.first] : const [];
        continue;
      }
      final pos = RegExp(r'^position\(\)\s*>\s*(\d+)$').firstMatch(p);
      if (pos != null) {
        final n = int.parse(pos.group(1)!);
        result = result.length > n ? result.sublist(n) : const [];
        continue;
      }
      final posGtEq = RegExp(r'^position\(\)\s*>=\s*(\d+)$').firstMatch(p);
      if (posGtEq != null) {
        final n = int.parse(posGtEq.group(1)!);
        result = result.length > n - 1 ? result.sublist(n - 1) : const [];
        continue;
      }
      // 属性谓词 [@attr] / [@attr="val"] / [@attr='val'] / [contains(@attr,'s')]
      final attrHas = RegExp(r'^@([\w-]+)$').firstMatch(p);
      if (attrHas != null) {
        final a = attrHas.group(1)!;
        result = result.where((e) => _hasAttr(e, a)).toList();
        continue;
      }
      final attrEq = RegExp(r'^@([\w-]+)\s*=\s*[\x22\x27]([^\x22\x27]*)[\x22\x27]$').firstMatch(p);
      if (attrEq != null) {
        final a = attrEq.group(1)!, v = attrEq.group(2)!;
        result = result.where((e) => _attrOf(e, a) == v).toList();
        continue;
      }
      final attrContains = RegExp(r'^contains\(@([\w-]+)\s*,\s*[\x22\x27]([^\x22\x27]*)[\x22\x27]\)$').firstMatch(p);
      if (attrContains != null) {
        final a = attrContains.group(1)!, v = attrContains.group(2)!;
        result = result.where((e) => _attrOf(e, a).contains(v)).toList();
        continue;
      }
      // 文本谓词 [text()="val"] / [.="val"] / [normalize-space(.)="val"] / [contains(.,'val')]
      final textEq = RegExp(r'^(?:text\(\)|\.)\s*=\s*[\x22\x27]([^\x22\x27]*)[\x22\x27]$').firstMatch(p);
      if (textEq != null) {
        final v = textEq.group(1)!;
        result = result.where((e) => _norm(e.text) == _norm(v)).toList();
        continue;
      }
      final normEq = RegExp(r'^normalize-space\(\.\)\s*=\s*[\x22\x27]([^\x22\x27]*)[\x22\x27]$').firstMatch(p);
      if (normEq != null) {
        final v = _norm(normEq.group(1)!);
        result = result.where((e) => _norm(e.text) == v).toList();
        continue;
      }
      final containsText = RegExp(r'^contains\((?:\.|text\(\))\s*,\s*[\x22\x27]([^\x22\x27]*)[\x22\x27]\)$').firstMatch(p);
      if (containsText != null) {
        final v = containsText.group(1)!;
        result = result.where((e) => e.text.contains(v)).toList();
        continue;
      }
      // 未能识别的谓词：宽容放行（不做过滤）
    }
    return result;
  }

  static bool _hasAttr(dom.Element e, String a) => e.attributes.containsKey(a);
  static String _attrOf(dom.Element e, String a) => e.attributes[a] ?? '';
  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 属性/文本终端值包装：与 Element 区分，转字符串时返回原始值。
class _AttrText {
  const _AttrText(this.value);
  final String value;
}

/// 解析步骤的本体（去掉 `[..]` 谓词）。
String _stripPredicates(String step) {
  final idx = step.indexOf('[');
  return idx < 0 ? step : step.substring(0, idx);
}

/// 提取步骤中所有 `[...]` 谓词内容。
List<String> _extractPredicates(String step) {
  final out = <String>[];
  var i = 0;
  while (i < step.length) {
    final open = step.indexOf('[', i);
    if (open < 0) break;
    final close = step.indexOf(']', open);
    if (close < 0) break;
    out.add(step.substring(open + 1, close));
    i = close + 1;
  }
  return out;
}

/// 按 `/` 切分步骤，跳过 `[ ]` / `( )` 内的斜杠。
List<String> _splitSteps(String s) {
  final steps = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '[' || c == '(') {
      depth++;
      buf.write(c);
    } else if (c == ']' || c == ')') {
      if (depth > 0) depth--;
      buf.write(c);
    } else if (c == '/' && depth == 0) {
      if (buf.isNotEmpty) {
        steps.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(c);
    }
  }
  if (buf.isNotEmpty) steps.add(buf.toString());
  return steps;
}