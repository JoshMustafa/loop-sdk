
import 'loop_analytics_platform_interface.dart';

class LoopAnalytics {
  Future<String?> getPlatformVersion() {
    return LoopAnalyticsPlatform.instance.getPlatformVersion();
  }
}
