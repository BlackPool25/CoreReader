import 'dart:io' show Platform;

bool defaultUseLocalTtsImpl() => Platform.isAndroid;
