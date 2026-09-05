// HTTP TTS 引擎服务单元测试：模型往返 + header 解析 + 语速映射 + 音频抓取行为。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/services/http_tts_engine_service.dart';

HttpTtsEngine _engine({
  String id = 'e1',
  String url = 'https://api.example.com/tts?text={{speakText}}&speed={{speakSpeed}}',
  String? contentType = 'audio/mpeg',
  int pauseDuration = 0,
  bool enabledCookieJar = false,
  String? loginUrl,
  String? header,
  String? loginCheckJs,
}) => HttpTtsEngine(
  id: id,
  name: '测试引擎',
  url: url,
  contentType: contentType,
  pauseDuration: pauseDuration,
  enabledCookieJar: enabledCookieJar,
  loginUrl: loginUrl,
  header: header,
  loginCheckJs: loginCheckJs,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HttpTtsEngine 模型', () {
    test('toJson / fromJson 往返保留全部字段', () {
      final engine = _engine(
        id: 'e9',
        url: 'https://x.test/a?t={{speakText}}',
        contentType: 'audio/wav',
        pauseDuration: 800,
        enabledCookieJar: true,
        loginUrl: 'https://x.test/login',
        header: '{"Authorization":"Bearer x"}',
        loginCheckJs: 'response.code == 500 ? "500" : ""',
      );
      final restored = HttpTtsEngine.fromJson(engine.toJson());
      expect(restored.id, 'e9');
      expect(restored.name, '测试引擎');
      expect(restored.contentType, 'audio/wav');
      expect(restored.pauseDuration, 800);
      expect(restored.enabledCookieJar, isTrue);
      expect(restored.loginUrl, 'https://x.test/login');
      expect(restored.loginCheckJs?.contains('500'), isTrue);
    });

    test('缺省字段返回安全默认值', () {
      final rule = HttpTtsEngine.fromJson(const {
        'id': 'x',
        'name': 'n',
        'url': 'u',
      });
      expect(rule.pauseDuration, 0);
      expect(rule.enabledCookieJar, isFalse);
      expect(rule.concurrentRate, '0');
      expect(rule.contentType, isNull);
    });

    test('pauseDuration 超界钳制到 0-10000', () {
      final rule = HttpTtsEngine.fromJson(const {
        'id': 'x',
        'name': 'n',
        'url': 'u',
        'pauseDuration': 99999,
      });
      expect(rule.pauseDuration, 10000);
    });
  });

  group('HttpTtsEngineService 仓库', () {
    test('增删改选与持久化', () async {
      final service = HttpTtsEngineService();
      await service.ensureLoaded();
      final engine = _engine(id: 'a');
      await service.add(engine);
      expect(service.activeEngineId, 'a');
      expect(service.hasEngines, isTrue);

      await service.update('a', engine.copyWith(name: '改名'));
      expect(service.engineById('a')!.name, '改名');

      await service.remove('a');
      expect(service.engines, isEmpty);
      expect(service.activeEngineId, isNull);
    });

    test('选中引擎保存在独立键，读取一致', () async {
      final service = HttpTtsEngineService();
      await service.ensureLoaded();
      await service.add(_engine(id: 'b'));
      await service.setActive('b');

      final reloaded = HttpTtsEngineService();
      await reloaded.ensureLoaded();
      expect(reloaded.activeEngineId, 'b');
    });
  });

  group('parseHttpTtsHeaders', () {
    test('JSON 对象字符串', () {
      final headers = parseHttpTtsHeaders('{"Authorization":"Bearer x","X-A":"1"}');
      expect(headers['Authorization'], 'Bearer x');
      expect(headers['X-A'], '1');
    });

    test('单引号 JSON 归一', () {
      final headers = parseHttpTtsHeaders("{'Authorization':'Bearer y'}");
      expect(headers['Authorization'], 'Bearer y');
    });

    test('键: 值 换行队列（headerQueue）', () {
      final headers = parseHttpTtsHeaders('User-Agent: test\r\nAccept: audio/*');
      expect(headers['User-Agent'], 'test');
      expect(headers['Accept'], 'audio/*');
    });

    test('空/空白返回空 Map', () {
      expect(parseHttpTtsHeaders(null), isEmpty);
      expect(parseHttpTtsHeaders('  '), isEmpty);
    });
  });

  group('speakSpeedFor 语速映射', () {
    test('0.1 → 6，0.5 → 10，1.0 → 15', () {
      expect(HttpTtsAudioFetcher.speakSpeedFor(0.1), 6);
      expect(HttpTtsAudioFetcher.speakSpeedFor(0.5), 10);
      expect(HttpTtsAudioFetcher.speakSpeedFor(1.0), 15);
    });
  });

  group('HttpTtsAudioFetcher 抓取行为', () {
    test('音频响应返回字节且注入 speakText/speakSpeed', () async {
      final requests = <LegadoRequestTemplate>[];
      final audio = Uint8List.fromList([1, 2, 3, 4]);
      final fetcher = HttpTtsAudioFetcher()
        ..requestOverride = (request) async {
          requests.add(request);
          return LegadoRawResponse(
            bytes: audio,
            finalUri: request.url,
            statusCode: 200,
            headers: const {'content-type': 'audio/mpeg'},
          );
        };

      final result = await fetcher.fetchAudio(
        engine: _engine(),
        text: '你好',
        rate: 0.5,
      );
      fetcher.close();

      expect(result, audio);
      final url = requests.single.url.toString();
      // {{speakText}} 已按 UTF-8 百分号编码展开，{{speakSpeed}} 替换为整数。
      expect(url, contains(Uri.encodeQueryComponent('你好')));
      expect(url, contains('speed=10'));
    });

    test('文本响应且无登录配置时报错', () async {
      final fetcher = HttpTtsAudioFetcher()
        ..requestOverride = (_) async => LegadoRawResponse(
              bytes: Uint8List.fromList('need login page'.codeUnits),
              finalUri: Uri.parse('https://x.test/tts'),
              statusCode: 200,
              headers: const {'content-type': 'text/html'},
            );

      expect(
        () => fetcher.fetchAudio(engine: _engine(), text: '你好', rate: 0.5),
        throwsA(isA<HttpTtsEngineException>()),
      );
      fetcher.close();
    });

    test('loginCheckJs 返回 500 判定登录失败', () async {
      final fetcher = HttpTtsAudioFetcher()
        ..requestOverride = (_) async => LegadoRawResponse(
              bytes: Uint8List.fromList('please login'.codeUnits),
              finalUri: Uri.parse('https://x.test/tts'),
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
            );

      expect(
        () => fetcher.fetchAudio(
          engine: _engine(loginCheckJs: 'response.code == 500 ? "500" : ""'),
          text: '你好',
          rate: 0.5,
        ),
        throwsA(isA<HttpTtsEngineException>()),
      );
      fetcher.close();
    });

    test('contentType 正则不匹配时按非音频处理报错', () async {
      final fetcher = HttpTtsAudioFetcher()
        ..requestOverride = (_) async => LegadoRawResponse(
              bytes: Uint8List.fromList([9, 9]),
              finalUri: Uri.parse('https://x.test/tts'),
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
            );

      expect(
        () => fetcher.fetchAudio(
          engine: _engine(contentType: 'audio/mpeg'),
          text: '你好',
          rate: 0.5,
        ),
        throwsA(isA<HttpTtsEngineException>()),
      );
      fetcher.close();
    });
  });
}