# 从 assets/se/ 母带生成规范命名的通知音效（assets/sounds/ + Android res/raw）。
# 正式素材到位后：覆盖 se/ 中对应母带并重跑本脚本，无需改代码。
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

$root = Split-Path -Parent $PSScriptRoot
$seDir = Join-Path $root 'apps/mobile_flutter/assets/se'
$outDir = Join-Path $root 'apps/mobile_flutter/assets/sounds'
$rawDir = Join-Path $root 'apps/mobile_flutter/android/app/src/main/res/raw'

function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}

function Copy-Asset {
    param([string]$Source, [string]$Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

# 首尾静音裁剪链：先裁头部，反转后裁尾部再反转回来。
$trimChain = 'silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse'

$messageSource = Join-Path $seDir 'message_reminder_se.mp3'
$sentSource = Join-Path $seDir 'voice_message sending_se.mp3'
$ringtoneSource = Join-Path $seDir 'video_call _ringtone_se.mp3'
$waitingSource = Join-Path $seDir 'video_call _waiting _se.mp3'
$hangupSource = Join-Path $seDir 'video_call _hang-up_se.mp3'
$redPacketSource = Join-Path $seDir 'red_packet_opening_se.mp3'
$scanSource = Join-Path $seDir 'scan_se.mp3'

# 1. 普通消息音：裁掉 0.8s 头部静音与尾部静音（PRD §5 要求快速起音、整体 <600ms）。
$messageReceived = Join-Path $outDir 'message_received.mp3'
& ffmpeg -hide_banner -loglevel error -y -i $messageSource -af $trimChain -codec:a libmp3lame -b:a 128k -ar 44100 -ac 1 $messageReceived
Assert-LastExitCode 'trim message_received'

# 2. 发送成功音：裁静音。
$messageSent = Join-Path $outDir 'message_sent.mp3'
& ffmpeg -hide_banner -loglevel error -y -i $sentSource -af $trimChain -codec:a libmp3lame -b:a 128k -ar 44100 -ac 1 $messageSent
Assert-LastExitCode 'trim message_sent'

# 3. 顶替拷贝（正式素材到位后覆盖 SE/ 母带并重跑即可替换）。
foreach ($name in 'message_attention.mp3', 'notification.mp3', 'mention.mp3') {
    Copy-Asset $messageReceived (Join-Path $outDir $name)
}
Copy-Asset $ringtoneSource (Join-Path $outDir 'call_video_incoming.mp3')
Copy-Asset $ringtoneSource (Join-Path $outDir 'call_voice_incoming.mp3')
Copy-Asset $waitingSource (Join-Path $outDir 'call_outgoing.mp3')
Copy-Asset $hangupSource (Join-Path $outDir 'call_ended.mp3')
Copy-Asset $redPacketSource (Join-Path $outDir 'redpacket_open.mp3')
foreach ($name in 'redpacket_received.mp3', 'diamond_received.mp3', 'transfer_received.mp3') {
    Copy-Asset $redPacketSource (Join-Path $outDir $name)
}
Copy-Asset $scanSource (Join-Path $outDir 'scan.mp3')

# 4. 接通确认音（顶替）：取呼叫等待音前 0.35s 并淡出，模拟轻确认音。
& ffmpeg -hide_banner -loglevel error -y -i $waitingSource -af 'atrim=0:0.35,afade=t=out:st=0.27:d=0.08' -codec:a libmp3lame -b:a 128k -ar 44100 -ac 1 (Join-Path $outDir 'call_connected.mp3')
Assert-LastExitCode 'trim call_connected'

# 5. Android 系统通知音（res/raw，OGG/Vorbis）：与 assets/sounds 同源。
foreach ($pair in @(
        @{ Raw = 'chatflow_message.ogg'; Src = $messageReceived },
        @{ Raw = 'chatflow_attention.ogg'; Src = $messageReceived },
        @{ Raw = 'chatflow_mention.ogg'; Src = $messageReceived },
        @{ Raw = 'chatflow_system.ogg'; Src = $messageReceived },
        # 后台/锁屏来电铃声（BUG2）：来电子渠道声音，由系统通知播放，
        # 不依赖应用内 audioplayers（进程被限/无焦点时仍可响铃）。
        @{ Raw = 'chatflow_ringtone.ogg'; Src = $ringtoneSource }
    )) {
    & ffmpeg -hide_banner -loglevel error -y -i $pair.Src -codec:a libvorbis -q:a 4 -ar 44100 -ac 1 (Join-Path $rawDir $pair.Raw)
    Assert-LastExitCode "ogg $($pair.Raw)"
}

Write-Output 'Notification sounds: PASS'
Get-ChildItem -LiteralPath $outDir | ForEach-Object {
    $duration = & ffprobe -v error -show_entries format=duration -of csv=p=0 -- $_.FullName
    '{0} => {1:N2}s' -f $_.Name, [double]$duration
}
