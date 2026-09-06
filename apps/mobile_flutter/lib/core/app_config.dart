import 'package:package_info_plus/package_info_plus.dart';

final class AppConfig {
  static const matrixHomeserver = String.fromEnvironment(
    'LIUHETONG_MATRIX_HOMESERVER',
    defaultValue: 'https://liuhetong888.com',
  );
  static const businessApiBaseUrl = String.fromEnvironment(
    'LIUHETONG_BUSINESS_API_URL',
    defaultValue: 'https://liuhetong888.com',
  );

  /// 应用内更新：检查新版本并跳转 APK 下载/安装。诊断（minimal）构建可用
  /// `--dart-define=LIUHETONG_IN_APP_UPDATE=false` 关闭——"下载 APK 并
  /// 拉起安装"是杀软灰名单启发式（Bulimia 类）的高危特征，二分定位时
  /// 需要能整体摘除该行为；生产构建保持默认开启。
  static const inAppUpdateEnabled = bool.fromEnvironment(
    'LIUHETONG_IN_APP_UPDATE',
    defaultValue: true,
  );

  /// Sygnal 推送网关（Matrix Pusher http 网关）根地址；构建时注入，如
  /// `--dart-define=LIUHETONG_SYGNAL_URL=https://push.example.com`。
  /// 为空（默认，凭据未配置）时客户端不注册 pusher，仅使用 Matrix 同步
  /// 通道；配置与部署步骤见 docs/PUSH_SETUP.md。
  static const sygnalPushGatewayUrl = String.fromEnvironment(
    'LIUHETONG_SYGNAL_URL',
  );

  /// 个推桥接网关（自建 Matrix Push Gateway → 个推）根地址；构建时注入，
  /// 如 `--dart-define=LIUHETONG_GETUI_URL=https://<域名>`。运行时解析为
  /// `<url>/_matrix/push/v1/getui/notify`。为空（默认）时客户端不注册
  /// 个推 pusher；服务端 getui-bridge 的密钥与部署见 docs/PUSH_SETUP.md。
  static const getuiPushGatewayUrl = String.fromEnvironment(
    'LIUHETONG_GETUI_URL',
  );

  /// Release identity of this build. Keep in sync with `version:` in
  /// pubspec.yaml; tests/mobile/test_app_build_contract.py asserts the match.
  /// 运行时由 [loadRuntimeVersion] 用安装包真实版本覆盖（见 main）。
  static String appVersionName = '0.3.42';
  static int appBuildNumber = 45;

  /// 从安装包清单读取真实版本，保证「关于畅聊」与更新判断使用实际值。
  static Future<void> loadRuntimeVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      appVersionName = info.version;
      final build = int.tryParse(info.buildNumber);
      if (build != null && build > 0) appBuildNumber = normalizeBuildNumber(build);
    } catch (_) {
      // 平台通道不可用（如测试环境）时保留 pubspec 同步的回退值。
    }
  }

  /// Android 按 ABI 分包会把 versionCode 写成 `abiIndex * 1000 + build`
  /// （如 arm64=2xxx、x86_64=4xxx）。与更新设置（pubspec 构建号）比较前
  /// 必须剥掉该偏移，否则 latest_build 永远小于当前构建、更新弹窗失效。
  static int normalizeBuildNumber(int build) => build >= 1000 ? build % 1000 : build;
}
