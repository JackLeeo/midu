// 文件说明：Web 管理服务器设置页组件测试（注入 fake service）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/pages/settings/web_server_page.dart';
import 'package:midu/services/web_server/web_console_service.dart';

class _FakeWebConsoleService extends WebConsoleService {
  _FakeWebConsoleService({bool running = false}) : isRunningValue = running;

  bool isRunningValue;
  String token = 'token-abc-123';
  int desiredPort = 18181;
  String? error;
  bool startRequested = false;
  bool stopRequested = false;
  int regenerated = 0;

  @override
  bool get isRunning => isRunningValue;

  @override
  Future<void> restore() async {}

  @override
  Future<void> setPort(int port) async {
    desiredPort = port;
    notifyListeners();
  }

  @override
  Future<bool> start() async {
    startRequested = true;
    isRunningValue = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> stop() async {
    stopRequested = true;
    isRunningValue = false;
    notifyListeners();
  }

  @override
  Future<void> regenerateToken() async {
    regenerated++;
    token = 'token-new-$regenerated';
    notifyListeners();
  }
}

Widget _testApp({required WebConsoleService service}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: WebServerPage(service: service),
  );
}

Future<void> _tapToggle(WidgetTester tester) async {
  final target = find.byKey(const ValueKey('web-server-toggle-button'));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders status, port, token and start button', (tester) async {
    final fake = _FakeWebConsoleService();
    await tester.pumpWidget(_testApp(service: fake));
    await tester.pump();

    expect(find.text('Web management server'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.byKey(const ValueKey('web-server-port-field')), findsOneWidget);
    expect(find.text('token-abc-123'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('web-server-toggle-button')),
      findsOneWidget,
    );
    expect(find.text('Start service'), findsOneWidget);
  });

  testWidgets('start switches to running state', (tester) async {
    final fake = _FakeWebConsoleService();
    await tester.pumpWidget(_testApp(service: fake));
    await tester.pump();

    await _tapToggle(tester);

    expect(fake.startRequested, isTrue);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Stop service'), findsOneWidget);
  });

  testWidgets('stop button stops the service', (tester) async {
    final fake = _FakeWebConsoleService(running: true);
    await tester.pumpWidget(_testApp(service: fake));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    await _tapToggle(tester);

    expect(fake.stopRequested, isTrue);
    expect(find.text('Stopped'), findsOneWidget);
  });

  testWidgets('regenerate token updates display', (tester) async {
    final fake = _FakeWebConsoleService();
    await tester.pumpWidget(_testApp(service: fake));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('web-server-regenerate-token-button')),
    );
    await tester.pump();

    expect(fake.regenerated, 1);
    expect(find.text('token-new-1'), findsOneWidget);
  });
}