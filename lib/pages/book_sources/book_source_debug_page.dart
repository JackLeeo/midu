// 书源调试页：对标 Legado BookSourceDebugActivity。
//
// 提供五个分区（搜索 / 详情 / 目录 / 正文 / JS·规则），每个分区发起一次真实
// 请求并展示规则解析结果；页面底部固定「调试日志」流，实时展示本会话中所有
// 请求/响应/错误/结果条目（URL、方法、状态码、耗时、请求头、响应头、正文预览）。
//
// 实现要点：
// - 使用独立 BookSourceClient（注入 BookSourceDebugRecorder），不污染共享
//   客户端缓存的 LegadoRuntime 变量/JS 状态，正常阅读链路零影响。
// - 日志缓冲为环形（最多 400 条），超出丢弃最旧；ChangeNotifier 驱动实时刷新。
import 'package:flutter/material.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_client.dart';
import '../../book_sources/services/book_source_debug_recorder.dart';

/// 调试页顶部分区。
enum _DebugTab { search, bookInfo, toc, content, js }

class BookSourceDebugPage extends StatefulWidget {
  const BookSourceDebugPage({
    super.key,
    required this.source,
    this.client,
  });

  final RegisteredBookSource source;

  /// 允许测试注入自定义 client；null 时页面自建（带调试记录器）。
  final BookSourceClient? client;

  @override
  State<BookSourceDebugPage> createState() => _BookSourceDebugPageState();
}

class _BookSourceDebugPageState extends State<BookSourceDebugPage> {
  late final BookSourceDebugRecorder _recorder;
  late final BookSourceClient _client;
  _DebugTab _tab = _DebugTab.search;

  // 搜索
  final _searchController = TextEditingController();
  final _searchPageController = TextEditingController(text: '1');

  // 详情 / 目录 / 正文共用 bookUrl（目录额外支持从详情页读取）
  final _bookUrlController = TextEditingController();
  final _chapterUrlController = TextEditingController();

  // JS·规则
  bool _jsMode = true; // true=JS 执行, false=规则求值
  final _jsCodeController = TextEditingController();
  final _jsBodyController = TextEditingController();
  final _jsBaseUrlController = TextEditingController();
  final _ruleInputController = TextEditingController();

  // 运行结果
  String? _searchResult;
  String? _bookInfoResult;
  String? _tocResult;
  String? _contentResult;
  String? _jsResult;
  bool _busy = false;

  final Set<int> _expandedOrders = {};

  @override
  void initState() {
    super.initState();
    _recorder = BookSourceDebugRecorder();
    _client =
        widget.client ??
        BookSourceClient(
          debugRecorder: _recorder,
          enableAjaxBridge: true,
        );
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    _recorder.dispose();
    _searchController.dispose();
    _searchPageController.dispose();
    _bookUrlController.dispose();
    _chapterUrlController.dispose();
    _jsCodeController.dispose();
    _jsBodyController.dispose();
    _jsBaseUrlController.dispose();
    _ruleInputController.dispose();
    super.dispose();
  }

  String get _sourceName => widget.source.name;

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===== 各分区执行逻辑 =====

  Future<void> _runSearch() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    final page = int.tryParse(_searchPageController.text.trim()) ?? 1;
    _recorder.recordInfo(
      stage: BookSourceDebugStage.search,
      sourceName: _sourceName,
      message: '开始搜索「$keyword」（第 $page 页）',
    );
    await _run(() async {
      try {
        final result = await _client.search(
          widget.source,
          keyword,
          page: page,
          pageSize: 20,
        );
        final buffer = StringBuffer();
        if (result.items.isEmpty) {
          buffer.write('（无搜索结果）');
        }
        for (final book in result.items) {
          buffer
            ..write('《${book.title}》')
            ..write(book.author.isEmpty ? '' : ' 作者：${book.author}')
            ..write(
              (book.latestChapter ?? '').isEmpty
                  ? ''
                  : ' 最新：${book.latestChapter}',
            )
            ..write('\n· ${book.id}\n');
        }
        final text = buffer.toString().trim();
        if (!mounted) return;
        setState(() => _searchResult = text.isEmpty ? '（无搜索结果）' : text);
      } catch (e) {
        _recorder.recordError(
          stage: BookSourceDebugStage.search,
          sourceName: _sourceName,
          message: '搜索失败：$e',
        );
        if (!mounted) return;
        setState(() => _searchResult = '搜索失败：$e');
      }
    });
  }

  Future<void> _runBookInfo([String? bookId]) async {
    final id = bookId ?? _bookUrlController.text.trim();
    if (id.isEmpty) return;
    _recorder.recordInfo(
      stage: BookSourceDebugStage.bookInfo,
      sourceName: _sourceName,
      message: '请求书籍详情：$id',
    );
    await _run(() async {
      try {
        final book = await _client.getBook(widget.source, id);
        final text = [
          '书名：${book.title}',
          '作者：${book.author}',
          if ((book.latestChapter ?? '').isNotEmpty) '最新：${book.latestChapter}',
          if ((book.status ?? '').isNotEmpty) '状态：${book.status}',
          if ((book.description ?? '').isNotEmpty) '简介：${book.description}',
          '详情 URL：${book.id}',
        ].join('\n');
        if (!mounted) return;
        setState(() {
          _bookUrlController.text = book.id;
          _bookInfoResult = text;
        });
      } catch (e) {
        _recorder.recordError(
          stage: BookSourceDebugStage.bookInfo,
          sourceName: _sourceName,
          message: '详情失败：$e',
        );
        if (!mounted) return;
        setState(() => _bookInfoResult = '详情失败：$e');
      }
    });
  }

  Future<void> _runToc() async {
    final id = _bookUrlController.text.trim();
    if (id.isEmpty) return;
    _recorder.recordInfo(
      stage: BookSourceDebugStage.toc,
      sourceName: _sourceName,
      message: '请求章节目录：$id',
    );
    await _run(() async {
      try {
        final chapters = await _client.getChapters(widget.source, id);
        final buffer = StringBuffer('共 ${chapters.length} 章：\n');
        for (final chapter in chapters.take(30)) {
          buffer
            ..write('${chapter.order + 1}. ${chapter.title}\n')
            ..write('   ${chapter.id}\n');
        }
        if (chapters.length > 30) {
          buffer.write('…（其余 ${chapters.length - 30} 章省略）\n');
        }
        final text = buffer.toString().trim();
        if (!mounted) return;
        setState(() => _tocResult = text);
      } catch (e) {
        _recorder.recordError(
          stage: BookSourceDebugStage.toc,
          sourceName: _sourceName,
          message: '目录失败：$e',
        );
        if (!mounted) return;
        setState(() => _tocResult = '目录失败：$e');
      }
    });
  }

  Future<void> _runContent() async {
    final bookId = _bookUrlController.text.trim();
    final chapterId = _chapterUrlController.text.trim();
    if (bookId.isEmpty || chapterId.isEmpty) return;
    _recorder.recordInfo(
      stage: BookSourceDebugStage.content,
      sourceName: _sourceName,
      message: '请求章节正文：$chapterId',
    );
    await _run(() async {
      try {
        final content = await _client.getChapterContent(
          widget.source,
          bookId: bookId,
          chapterId: chapterId,
        );
        final images = content.imageUrls;
        final text = content.contentType == 'application/x-imagelist'
            ? '（漫画章节）图片 ${images.length} 张\n${images.take(3).join('\n')}'
            : (content.content.length > 800
                ? content.content.substring(0, 800)
                : content.content);
        if (!mounted) return;
        setState(() => _contentResult = '共 ${content.content.length} 字符\n$text');
      } catch (e) {
        _recorder.recordError(
          stage: BookSourceDebugStage.content,
          sourceName: _sourceName,
          message: '正文失败：$e',
        );
        if (!mounted) return;
        setState(() => _contentResult = '正文失败：$e');
      }
    });
  }

  Future<void> _runJs() async {
    final code = _jsCodeController.text.trim();
    if (code.isEmpty) return;
    await _run(() async {
      final runtime = _client.legadoRuntimeForSource(widget.source);
      try {
        if (_jsMode) {
          final result = await runtime.debugEvalJs(
            code: code,
            sourceName: _sourceName,
            docHtml: _jsBodyController.text.trim().isEmpty
                ? null
                : _jsBodyController.text,
            baseUri: Uri.tryParse(_jsBaseUrlController.text.trim()),
          );
          if (!mounted) return;
          setState(() => _jsResult = result.isEmpty ? '（空结果）' : result);
        } else {
          final rule = _ruleInputController.text.trim();
          if (rule.isEmpty) return;
          final body = _jsBodyController.text.trim();
          if (body.isEmpty) return;
          final baseUri = Uri.tryParse(_jsBaseUrlController.text.trim()) ??
              Uri.parse('https://example.com/');
          final values = await runtime.debugEvaluateRule(body, baseUri, rule);
          final preview = values
              .map((v) => '$v')
              .where((s) => s.trim().isNotEmpty)
              .take(30)
              .join('\n');
          if (!mounted) return;
          setState(
            () => _jsResult = preview.isEmpty
                ? '（${values.length} 条结果，均为空值）'
                : '${values.length} 条结果：\n$preview',
          );
        }
      } catch (e) {
        _recorder.recordError(
          stage: BookSourceDebugStage.js,
          sourceName: _sourceName,
          message: '$e',
        );
        if (!mounted) return;
        setState(() => _jsResult = '执行失败：$e');
      }
    });
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('调试「$_sourceName」'),
        actions: [
          IconButton(
            tooltip: '清空调试日志',
            onPressed: _recorder.isEmpty
                ? null
                : () {
                    _recorder.clear();
                    _expandedOrders.clear();
                  },
            icon: const Icon(Icons.clear_all_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<_DebugTab>(
                    segments: const [
                      ButtonSegment(
                        value: _DebugTab.search,
                        label: Text('搜索'),
                        icon: Icon(Icons.search_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: _DebugTab.bookInfo,
                        label: Text('详情'),
                        icon: Icon(Icons.menu_book_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: _DebugTab.toc,
                        label: Text('目录'),
                        icon: Icon(Icons.list_alt_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: _DebugTab.content,
                        label: Text('正文'),
                        icon: Icon(Icons.article_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: _DebugTab.js,
                        label: Text('JS·规则'),
                        icon: Icon(Icons.code_rounded, size: 18),
                      ),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (value) =>
                        setState(() => _tab = value.first),
                  ),
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 860;
                  final operation = _buildOperationPanel();
                  final logPanel = _buildLogPanel();
                  if (wide) {
                    return Row(
                      children: [
                        SizedBox(width: constraints.maxWidth * 0.46, child: operation),
                        const VerticalDivider(width: 1),
                        Expanded(child: logPanel),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * 0.5,
                        ),
                        child: operation,
                      ),
                      Divider(
                        height: 1,
                        color: scheme.outline.withValues(alpha: 0.2),
                      ),
                      Expanded(child: logPanel),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOperationPanel() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        switch (_tab) {
          _DebugTab.search => _buildSearchPanel(),
          _DebugTab.bookInfo => _buildBookInfoPanel(),
          _DebugTab.toc => _buildTocPanel(),
          _DebugTab.content => _buildContentPanel(),
          _DebugTab.js => _buildJsPanel(),
        },
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildSearchPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('搜索调试'),
        TextField(
          controller: _searchController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '关键词',
            hintText: '输入书名/作者关键词',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search_rounded),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _runSearch(),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _searchPageController,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '页码',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                key: const Key('debugSearchButton'),
                onPressed: _busy ? null : _runSearch,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('搜索'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '提示：搜索结果的第一项是『《书名》 作者 最新…』，可复制其 URL 到详情/目录/正文分区的书址栏。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        if (_searchResult != null) ...[
          const SizedBox(height: 14),
          _resultCard('搜索结果', _searchResult!),
        ],
      ],
    );
  }

  Widget _buildBookInfoPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('详情调试'),
        TextField(
          controller: _bookUrlController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '书籍 URL（bookUrl）',
            hintText: '搜索到的书籍详情地址',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link_rounded),
          ),
        ),
        const SizedBox(height: 10),
        SearchAnchor(
          builder: (context, controller) => SearchBar(
            controller: controller,
            hintText: '从搜索结果选取…',
            leading: const Icon(Icons.book_rounded),
            shadowColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          suggestionsBuilder: (context, controller) => const [],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('debugBookInfoButton'),
          onPressed: _busy ? null : _runBookInfo,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: const Text('获取详情'),
        ),
        if (_bookInfoResult != null) ...[
          const SizedBox(height: 14),
          _resultCard('详情结果', _bookInfoResult!),
        ],
      ],
    );
  }

  Widget _buildTocPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('目录调试'),
        TextField(
          controller: _bookUrlController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '书籍 URL（bookUrl）',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link_rounded),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('debugTocButton'),
          onPressed: _busy ? null : _runToc,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: const Text('获取目录'),
        ),
        if (_tocResult != null) ...[
          const SizedBox(height: 14),
          _resultCard('目录结果（前 30 章）', _tocResult!),
        ],
      ],
    );
  }

  Widget _buildContentPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('正文调试'),
        TextField(
          controller: _bookUrlController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '书籍 URL（bookUrl）',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link_rounded),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _chapterUrlController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '章节 URL（chapterUrl）',
            hintText: '目录中的章节地址',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.file_open_rounded),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('debugContentButton'),
          onPressed: _busy ? null : _runContent,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: const Text('获取正文'),
        ),
        if (_contentResult != null) ...[
          const SizedBox(height: 14),
          _resultCard('正文结果', _contentResult!),
        ],
      ],
    );
  }

  Widget _buildJsPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('JS / 规则调试'),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('JS 执行'),
              icon: Icon(Icons.terminal_rounded, size: 16),
            ),
            ButtonSegment(
              value: false,
              label: Text('规则求值'),
              icon: Icon(Icons.transform_rounded, size: 16),
            ),
          ],
          selected: {_jsMode},
          onSelectionChanged: (value) =>
              setState(() => _jsMode = value.first),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _jsMode ? _jsCodeController : _ruleInputController,
          enabled: !_busy,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(
            labelText: _jsMode ? 'JS 代码（可带 @js:/<js>）' : '规则表达式',
            hintText: _jsMode ? '如 finalResult = java.md5Encode(key);' : '如 .book-list li@text',
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 10),
        if (!_jsMode) ...[
          TextField(
            controller: _jsBodyController,
            enabled: !_busy,
            maxLines: 5,
            minLines: 3,
            decoration: const InputDecoration(
              labelText: '待解析内容（HTML/JSON）',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
        ],
        TextField(
          controller: _jsBaseUrlController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '基准 URL（baseUrl，可选）',
            hintText: '如 https://example.com/book/1.html',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('debugJsButton'),
          onPressed: _busy ? null : _runJs,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: Text(_jsMode ? '执行 JS' : '求值规则'),
        ),
        if (_jsResult != null) ...[
          const SizedBox(height: 14),
          _resultCard(_jsMode ? 'JS 结果' : '规则结果', _jsResult!),
        ],
      ],
    );
  }

  Widget _resultCard(String title, String content) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            content,
            style: const TextStyle(fontSize: 12.5, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ===== 调试日志流 =====

  Widget _buildLogPanel() {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _recorder,
      builder: (context, _) {
        final entries = _recorder.entries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '调试日志（${_recorder.length}）',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '最新在最前',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志。\n在上方分区执行一次搜索/详情/目录/正文/JS 后，\n这里会展示每个请求与响应。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        // entries 从旧到新，列表里最新在前
                        final entry = entries[entries.length - 1 - index];
                        return _buildLogEntry(entry);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLogEntry(BookSourceDebugEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedOrders.contains(entry.order);
    final Color accent = switch (entry.kind) {
      BookSourceDebugKind.request => scheme.primary,
      BookSourceDebugKind.response => Colors.green,
      BookSourceDebugKind.error => scheme.error,
      BookSourceDebugKind.ruleResult => scheme.tertiary,
      BookSourceDebugKind.info => scheme.onSurfaceVariant,
    };
    final icon = switch (entry.kind) {
      BookSourceDebugKind.request => Icons.call_made_rounded,
      BookSourceDebugKind.response => Icons.call_received_rounded,
      BookSourceDebugKind.error => Icons.error_outline_rounded,
      BookSourceDebugKind.ruleResult => Icons.rule_rounded,
      BookSourceDebugKind.info => Icons.info_outline_rounded,
    };
    final hasDetail = entry.url != null &&
        (entry.method != null ||
            entry.requestHeaders != null ||
            entry.requestBody != null ||
            entry.responseHeaders != null ||
            entry.message != null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: !hasDetail
              ? null
              : () => setState(() {
                    _expandedOrders.add(entry.order);
                    if (expanded) _expandedOrders.remove(entry.order);
                  }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 17, color: accent),
                    const SizedBox(width: 7),
                    Text(
                      entry.kindLabel,
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _chip(entry.stageLabel, scheme),
                    const Spacer(),
                    if (entry.statusCode != null)
                      Text(
                        '${entry.statusCode}',
                        style: TextStyle(
                          color: entry.statusCode! >= 300 && entry.statusCode! < 500
                              ? Colors.orange
                              : entry.statusCode! >= 500
                              ? scheme.error
                              : Colors.green,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    if (entry.elapsedMs != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${entry.elapsedMs}ms',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (entry.message != null &&
                    (entry.kind != BookSourceDebugKind.request &&
                        entry.kind != BookSourceDebugKind.response)) ...[
                  Text(
                    entry.message!,
                    maxLines: expanded ? null : 2,
                    overflow: expanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                if (entry.url != null)
                  SelectableText(
                    entry.url!,
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                    maxLines: expanded ? null : 2,
                  ),
                if (expanded && hasDetail) ...[
                  const SizedBox(height: 6),
                  _logDetailLines(entry, scheme),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _logDetailLines(BookSourceDebugEntry entry, ColorScheme scheme) {
    final lines = <String>[];
    if (entry.method != null && entry.url != null) {
      lines.add('${entry.method} ${entry.url}');
    }
    if (entry.requestHeaders != null && entry.requestHeaders!.isNotEmpty) {
      lines
        ..add('— 请求头 —')
        ..addAll(entry.requestHeaders!.entries.map((e) => '${e.key}: ${e.value}'));
    }
    if (entry.requestBody != null && entry.requestBody!.isNotEmpty) {
      lines
        ..add('— 请求体 —')
        ..add(entry.requestBody!);
    }
    if (entry.responseHeaders != null && entry.responseHeaders!.isNotEmpty) {
      lines
        ..add('— 响应头 —')
        ..addAll(entry.responseHeaders!.entries.map((e) => '${e.key}: ${e.value}'));
    }
    if (entry.message != null &&
        (entry.kind == BookSourceDebugKind.response ||
            entry.kind == BookSourceDebugKind.error)) {
      lines
        ..add('— 正文预览 —')
        ..add(entry.message!);
    }
    return SelectableText(
      lines.join('\n'),
      style: TextStyle(
        fontSize: 11.5,
        height: 1.45,
        fontFamily: 'monospace',
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _chip(String text, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}