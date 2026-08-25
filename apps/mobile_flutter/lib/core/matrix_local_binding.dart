final class MatrixLocalBinding {
  factory MatrixLocalBinding({
    required int version,
    required String matrixUserId,
    required String deviceId,
    required String homeserver,
    required String databaseGeneration,
    String? ed25519Fingerprint,
  }) {
    if (version != 1 && version != 2) {
      throw const FormatException('Unsupported matrix local binding version');
    }

    String requireOpaqueValue(String value, String field) {
      if (value.isEmpty || value != value.trim()) {
        throw FormatException('Invalid matrix local binding $field');
      }
      return value;
    }

    if (version == 1 && ed25519Fingerprint != null) {
      throw const FormatException(
        'Legacy matrix local binding cannot contain a fingerprint',
      );
    }
    if (version == 2 && ed25519Fingerprint == null) {
      throw const FormatException(
          'Matrix local binding fingerprint is missing');
    }

    return MatrixLocalBinding._(
      version: version,
      matrixUserId: requireOpaqueValue(matrixUserId, 'matrix_user_id'),
      deviceId: requireOpaqueValue(deviceId, 'device_id'),
      homeserver: requireOpaqueValue(homeserver, 'homeserver'),
      databaseGeneration: requireOpaqueValue(
        databaseGeneration,
        'database_generation',
      ),
      ed25519Fingerprint: ed25519Fingerprint == null
          ? null
          : requireOpaqueValue(
              ed25519Fingerprint,
              'ed25519_fingerprint',
            ),
    );
  }

  const MatrixLocalBinding._({
    required this.version,
    required this.matrixUserId,
    required this.deviceId,
    required this.homeserver,
    required this.databaseGeneration,
    required this.ed25519Fingerprint,
  });

  factory MatrixLocalBinding.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final matrixUserId = json['matrix_user_id'];
    final deviceId = json['device_id'];
    final homeserver = json['homeserver'];
    final databaseGeneration = json['database_generation'];
    final ed25519Fingerprint = json['ed25519_fingerprint'];
    final allowedKeys = version == 1
        ? const {
            'version',
            'matrix_user_id',
            'device_id',
            'homeserver',
            'database_generation',
          }
        : const {
            'version',
            'matrix_user_id',
            'device_id',
            'homeserver',
            'database_generation',
            'ed25519_fingerprint',
          };
    if (version is! int ||
        matrixUserId is! String ||
        deviceId is! String ||
        homeserver is! String ||
        databaseGeneration is! String ||
        (ed25519Fingerprint != null && ed25519Fingerprint is! String) ||
        json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Invalid matrix local binding');
    }
    return MatrixLocalBinding(
      version: version,
      matrixUserId: matrixUserId,
      deviceId: deviceId,
      homeserver: homeserver,
      databaseGeneration: databaseGeneration,
      ed25519Fingerprint: ed25519Fingerprint as String?,
    );
  }

  final int version;
  final String matrixUserId;
  final String deviceId;
  final String homeserver;
  final String databaseGeneration;
  final String? ed25519Fingerprint;

  Map<String, dynamic> toJson() => {
        'version': version,
        'matrix_user_id': matrixUserId,
        'device_id': deviceId,
        'homeserver': homeserver,
        'database_generation': databaseGeneration,
        if (ed25519Fingerprint != null)
          'ed25519_fingerprint': ed25519Fingerprint,
      };

  @override
  bool operator ==(Object other) =>
      other is MatrixLocalBinding &&
      other.version == version &&
      other.matrixUserId == matrixUserId &&
      other.deviceId == deviceId &&
      other.homeserver == homeserver &&
      other.databaseGeneration == databaseGeneration &&
      other.ed25519Fingerprint == ed25519Fingerprint;

  @override
  int get hashCode => Object.hash(
        version,
        matrixUserId,
        deviceId,
        homeserver,
        databaseGeneration,
        ed25519Fingerprint,
      );
}
