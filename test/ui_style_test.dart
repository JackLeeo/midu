import 'package:flutter_test/flutter_test.dart';
import 'package:midu/utils/ui_style.dart';

void main() {
  group('appUiStyleFromStorage', () {
    test('defaults to glass so glass effects start enabled', () {
      expect(appUiStyleFromStorage(null), AppUiStyle.glass);
    });

    test('keeps explicitly saved glass preference', () {
      expect(appUiStyleFromStorage('glass'), AppUiStyle.glass);
    });
  });
}
