from pathlib import Path

root = Path('apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call')

# 1) CallBridge：eventCallEnded 常量引用
p = root / 'CallBridge.kt'
raw = p.read_text(encoding='utf-8')
raw = raw.replace('NativeCallBridge.emitToFlutter(NativeCallBridge.eventCallEnded)',
                  'NativeCallBridge.emitToFlutter("callEnded")', 1)
p.write_text(raw, encoding='utf-8', newline='')

# 2) CallConnectionService：Uri→String + DisconnectCause 全限定
p = root / 'CallConnectionService.kt'
raw = p.read_text(encoding='utf-8')
raw = raw.replace(
    'putString(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("tel:$callId"))',
    'putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("tel:$callId"))', 1)
raw = raw.replace(
    'setDisconnected(DisconnectCause(android.telecom.DisconnectCause.REJECTED))',
    'setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.REJECTED))', 1)
raw = raw.replace(
    'setDisconnected(DisconnectCause(android.telecom.DisconnectCause.LOCAL))',
    'setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))', 1)
p.write_text(raw, encoding='utf-8', newline='')

# 3) CallOverlayService：背景资源换纯色 drawable 代码方式
p = root / 'CallOverlayService.kt'
raw = p.read_text(encoding='utf-8')
raw = raw.replace(
    'setBackgroundResource(android.R.drawable.dialog_halo_frame)',
    'setBackgroundColor(0xE607C160.toInt())', 1)
p.write_text(raw, encoding='utf-8', newline='')
print('OK')
