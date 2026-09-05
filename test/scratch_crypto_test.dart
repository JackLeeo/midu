import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  copyQuickJsDllIfNeeded();
  test('sandbox crypto vectors', () async {
    final s = FlutterLegadoJsSandbox();
    await s.init();
    final md5abc = await s.evalJs('<js>java.md5Encode("abc")</js>');
    final md5a = await s.evalJs('<js>java.md5Encode("a")</js>');
    final md5ab = await s.evalJs('<js>java.md5Encode("ab")</js>');
    final md5empty = await s.evalJs('<js>java.crypto.md5Encode("")</js>');
    final sha1abc = await s.evalJs('<js>java.crypto.sha1Encode("abc")</js>');
    final sha256abc = await s.evalJs('<js>java.crypto.sha256Encode("abc")</js>');
    final b64abc = await s.evalJs('<js>java.base64Encode("abc")</js>');
    // 书旗签名向量：o = bookId+timestamp+user_id+encryptKey
    final ochen = '60874461787324653800000037e81a9d8f02596e1b895d07c171d5c9';
    final shuqiSign = await s.evalJs('<js>java.md5Encode("$ochen")</js>');
    print('shuqiSign md5=$shuqiSign (expect c3a16720723bb3ae4aee5358e72aaa82)');
    // 字面量 MD5 调试：标准 md5("abc")=900150983cd24fb0d6963f7d28e17f72
    final dbg = await s.evalJs('<js>__md5("abc")</js>');
    print('literal __md5("abc")=$dbg (expect 900150983cd24fb0d6963f7d28e17f72)');
    final utf8abc = await s.evalJs('<js>JSON.stringify(__utf8("abc"))</js>');
    print('__utf8("abc")=$utf8abc (expect [97,98,99])');
    print('md5("abc")=$md5abc');
    print('md5("a")=$md5a');
    print('md5("ab")=$md5ab');
    print('md5("")=$md5empty');
    print('sha1("abc")=$sha1abc');
    print('sha256("abc")=$sha256abc');
    print('b64("abc")=$b64abc');
    final triv = await s.evalJs('<js>1+1</js>');
    print('trivial 1+1=$triv (err=${s.lastError})');
    await s.dispose();
  });

  // 对齐 猫眼看书 等源 `java.aesBase64DecodeToString(data, key, mode, iv)`。
  // 密文为本地用同一套 AES(ECB/CBC + PKCS7) 对「musha是中文正文内容测试」加密所得。
  group('LegadoFjsSandbox.aesBase64DecodeToString', () {
    const key = '0123456789abcdef';
    const iv = 'fedcba9876543210';
    const plain = 'musha是中文正文内容测试';
    const ecbB64 = 'hUgdJLTZhYHIPJqGpZ7LwO+AtSvlEOwzVSqTGpU6vH83ciLgYakkxZHNnCfqFj7U';
    const cbcB64 = 'g+mgxJjPKMJ6FeG0RRr0P8NAcXr2Za14lyyxRwfSb+fwHqkv22FBiovSPDchpUZH';

    test('ECB 解密还原中文明文', () {
      expect(LegadoFjsSandbox().aesBase64DecodeToString(ecbB64, key, 'AES/ECB/PKCS7Padding', ''), plain);
    });

    test('CBC 解密还原中文明文', () {
      expect(
        LegadoFjsSandbox().aesBase64DecodeToString(cbcB64, key, 'AES/CBC/PKCS7Padding', iv),
        plain,
      );
    });

    test('模式串缩写 ECB / CBC 亦被识别', () {
      final s = LegadoFjsSandbox();
      expect(s.aesBase64DecodeToString(ecbB64, key, 'ECB', ''), plain);
      expect(s.aesBase64DecodeToString(cbcB64, key, 'CBC', iv), plain);
    });

    test('错误密钥/IV 解密返回空或乱码但不抛异常', () {
      // 不会抛异常（_aes 内 try/catch / allowMalformed）
      final wrong = LegadoFjsSandbox().aesBase64DecodeToString(ecbB64, '0000000000000000', 'ECB', '');
      expect(wrong, isNot(plain));
    });

    test('无效 base64 输入返回空', () {
      expect(
        LegadoFjsSandbox().aesBase64DecodeToString('!!!not-base64!!!', key, 'ECB', ''),
        '',
      );
    });
  });
}