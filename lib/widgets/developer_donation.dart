// 开发者捐赠相关存根
import 'package:flutter/widgets.dart';

enum DeveloperDonationMethod { alipay, wechat, paypal, buyMeACoffee }

class DeveloperDonationDialog {
  DeveloperDonationDialog._();

  static Future<void> show(
    BuildContext context, {
    DeveloperDonationMethod? method,
  }) async {
    // 存根：暂不实现捐赠弹窗 UI。
  }
}
