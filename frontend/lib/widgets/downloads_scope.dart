import 'package:flutter/material.dart';

import '../services/downloads_controller.dart';

class DownloadsScope extends InheritedNotifier<DownloadsController> {
  const DownloadsScope({
    super.key,
    required DownloadsController controller,
    required super.child,
  }) : super(notifier: controller);

  static DownloadsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DownloadsScope>();
    assert(scope != null, 'DownloadsScope not found in widget tree');
    return scope!.notifier!;
  }
}
