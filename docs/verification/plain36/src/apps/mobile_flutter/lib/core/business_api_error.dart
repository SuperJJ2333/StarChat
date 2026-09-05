final class BusinessApiException implements Exception {
  const BusinessApiException(
      {required this.statusCode,
      required this.code,
      required this.message,
      this.fieldErrors = const {}});
  final int statusCode;
  final String code;
  final String message;
  final Map<String, String> fieldErrors;
  @override
  String toString() => message;
}
