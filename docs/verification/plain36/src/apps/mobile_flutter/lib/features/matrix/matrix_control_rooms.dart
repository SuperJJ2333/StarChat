const matrixControlRoomNames = {'畅聊表情仓库', '畅聊提醒同步'};

bool isMatrixControlRoomName(String name) =>
    matrixControlRoomNames.contains(name);

bool isMatrixControlRoom({
  required String roomId,
  required String displayName,
  String? vaultRoomId,
  String? reminderRoomId,
}) =>
    roomId == vaultRoomId ||
    roomId == reminderRoomId ||
    isMatrixControlRoomName(displayName);
