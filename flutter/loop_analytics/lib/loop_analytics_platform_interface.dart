import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'loop_analytics_method_channel.dart';

abstract class LoopAnalyticsPlatform extends PlatformInterface {
  /// Constructs a LoopAnalyticsPlatform.
  LoopAnalyticsPlatform() : super(token: _token);

  static final Object _token = Object();

  static LoopAnalyticsPlatform _instance = MethodChannelLoopAnalytics();

  /// The default instance of [LoopAnalyticsPlatform] to use.
  ///
  /// Defaults to [MethodChannelLoopAnalytics].
  static LoopAnalyticsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [LoopAnalyticsPlatform] when
  /// they register themselves.
  static set instance(LoopAnalyticsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
