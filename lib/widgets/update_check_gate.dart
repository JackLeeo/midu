// 米读：更新检查 Gate
// 注：A + 紫 模式（巨魔/自签安装）不上架 App Store，所以不做 OTA 更新校验；
// 本 Widget 仅作为 main.dart 的导入兼容层，直接透传 child。
import 'package:flutter/material.dart';

// 透传 UpdatePromptController，便于已 import 本文件的调用方使用。
export 'update_prompt_controller.dart';

class UpdateCheckGate extends StatefulWidget {
  const UpdateCheckGate({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateCheckGate> createState() => _UpdateCheckGateState();
}

class _UpdateCheckGateState extends State<UpdateCheckGate> {
  @override
  Widget build(BuildContext context) => widget.child;
}
