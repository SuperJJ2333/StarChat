/// Optional read-only media capability. The SDK caches the server response;
/// callers must resolve it before loading a selected file into memory.
abstract interface class MatrixMediaUploadLimitGateway {
  Future<int?> maximumUploadBytes();
}
