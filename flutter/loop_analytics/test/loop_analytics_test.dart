import 'package:flutter_test/flutter_test.dart';
import 'package:loop_analytics/loop_analytics.dart';
import 'package:loop_analytics/loop_analytics_platform_interface.dart';
import 'package:loop_analytics/loop_analytics_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockLoopAnalyticsPlatform
    with MockPlatformInterfaceMixin
    implements LoopAnalyticsPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final LoopAnalyticsPlatform initialPlatform = LoopAnalyticsPlatform.instance;

  test('$MethodChannelLoopAnalytics is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelLoopAnalytics>());
  });

  test('getPlatformVersion', () async {
    LoopAnalytics loopAnalyticsPlugin = LoopAnalytics();
    MockLoopAnalyticsPlatform fakePlatform = MockLoopAnalyticsPlatform();
    LoopAnalyticsPlatform.instance = fakePlatform;

    expect(await loopAnalyticsPlugin.getPlatformVersion(), '42');
  });
}
