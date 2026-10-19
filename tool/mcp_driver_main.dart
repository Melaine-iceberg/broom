import 'package:broom/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';

/// Development-only entrypoint used by the Dart MCP server.
///
/// It enables the Flutter Driver extension so an agent can inspect the
/// running app, take screenshots, and perform semantic taps. Release builds
/// use `lib/main.dart` and never include this entrypoint.
///
/// The driver extension must be enabled before any Flutter binding is
/// initialized; it installs the binding used by the rest of the app.
void main(List<String> args) {
  enableFlutterDriverExtension();
  debugPrint('Broom MCP driver entrypoint enabled');
  app.main(args);
}
