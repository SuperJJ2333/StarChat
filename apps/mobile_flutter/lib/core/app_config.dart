final class AppConfig {
  static const matrixHomeserver = String.fromEnvironment(
    'LIUHETONG_MATRIX_HOMESERVER',
    defaultValue: 'http://127.0.0.1:8008',
  );
  static const businessApiBaseUrl = String.fromEnvironment(
    'LIUHETONG_BUSINESS_API_URL',
    defaultValue: 'http://127.0.0.1:8082',
  );
}
