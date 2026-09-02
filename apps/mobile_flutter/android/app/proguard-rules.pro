# 畅聊 Android R8 规则
# 目标：在开启混淆/收缩的同时，保留运行期反射与 JNI 需要的符号，
# 避免安全厂商对"高熵未知 so + 缺失符号信息"给出灰度过高评分。

# Flutter 引擎与 Dart AOT 通过 JNI 按名查找入口
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# sqlcipher / sqlite（加密聊天库，JNI 按名绑定）
-keep class net.sqlcipher.** { *; }
-keep class net.zetetic.database.** { *; }

# WebRTC（音视频通话 JNI）
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# record / speech_to_text / flutter_local_notifications 平台通道按名反射
-keep class com.llfbandit.record.** { *; }
-keep class com.csdcorp.speech_to_text.** { *; }
-keep class com.dexterous.** { *; }

# 保留源码行号与源文件名（崩溃堆栈可读，也向厂商证明非加固壳）
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
