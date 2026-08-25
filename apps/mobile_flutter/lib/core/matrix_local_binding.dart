final class MatrixLocalBinding {
  factory MatrixLocalBinding({
    required int version,
    required String matrixUserId,
    required String deviceId,
    required String homeserver,
    required String databaseGeneration,
  }) {
    if (version != 1) {
      throw const FormatException('Unsupported matrix local binding version');
    }

    String requireValue(String value, String field) {
      final normalized = value.trim();
      if (normalized.isEmpty) {
        throw FormatException('Invalid matrix local binding $field');
      }
      return normalized;
    }

    return MatrixLocalBinding._(
      version: version,
      matrixUserId: requireValue(matrixUserId, 'matrix_user_id'),
      deviceId: requireValue(deviceId, 'device_id'),
      homeserver: requireValue(homeserver, 'homeserver'),
      databaseGeneration: requireValue(
        databaseGeneration,
        'database_generation',
      ),
    );
  }

  const MatrixLocalBinding._({
    required this.version,
    required this.matrixUserId,
    required this.deviceId,
    required this.homeserver,
    required this.databaseGeneration,
  });

  factory MatrixLocalBinding.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final matrixUserId = json['matrix_user_id'];
    final deviceId = json['device_id'];
    final homeserver = json['homeserver'];
    final databaseGeneration = json['database_generation'];
    if (version is! int ||
        matrixUserId is! String ||
        deviceId is! String ||
        homeserver is! String ||
        databaseGeneration is! String) {
      throw const FormatException('Invalid matrix local binding');
    }
    return MatrixLocalBinding(
      version: version,
      matrixUserId: matrixUserId,
      deviceId: deviceId,
      homeserver: homeserver,
      databaseGeneration: databaseGeneration,
    );
  }

  final int version;
  final String matrixUserId;
  final String deviceId;
  final String homeserver;
  final String databaseGeneration;

  Map<String, dynamic> toJson() => {
        'version': version,
        'matrix_user_id': matrixUserId,
        'device_id': deviceId,
        'homeserver': homeserver,
        'database_generation': databaseGeneration,
      };

  @override
  bool operator ==(Object other) =>
      other is MatrixLocalBinding &&
      other.version == version &&
      other.matrixUserId == matrixUserId &&
      other.deviceId == deviceId &&
      other.homeserver == homeserver &&
      other.databaseGeneration == databaseGeneration;

  @override
  int get hashCode => Object.hash(
        version,
        matrixUserId,
        deviceId,
        homeserver,
        databaseGeneration,
      );
}
