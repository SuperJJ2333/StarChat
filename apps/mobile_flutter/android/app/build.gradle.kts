import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM 推送（可选凭据）：仅在放置了 android/app/google-services.json 时
// 应用 google-services 插件。凭据缺失时 FirebaseApp 不初始化，
// FirebasePushTokenProvider 运行时安全降级（token = null → 不注册
// pusher），构建产物与无 FCM 时完全一致。
// 配置步骤见 docs/PUSH_SETUP.md；不得提交真实 google-services.json。
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

val signingProperties = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.exists()) signingFile.inputStream().use { signingProperties.load(it) }

android {
    namespace = "com.liuhetong.mobile"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    // 安全审计诊断构建（docs/ANDROID_SECURITY_AUDIT.md）：
    // standard = 生产行为不变；minimal = 权限/高危行为裁剪起点，
    // 用于与杀软误报做二分定位。
    flavorDimensions += "edition"
    productFlavors {
        create("standard") { dimension = "edition" }
        create("minimal") {
            dimension = "edition"
            applicationIdSuffix = ".audit"
            versionNameSuffix = "-audit"
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.liuhetong.mobile"
        // 个推公开 AppID（个推控制台公开标识，允许随客户端分发；
        // AppKey/AppSecret 绝不入客户端，见 docs/PUSH_SETUP.md）。
        manifestPlaceholders["GETUI_APPID"] = "bL4tz01WK57ym4PVBGCUS1"
        // 个推安装渠道占位（SDK manifest 合并需要；值自报即可）。
        manifestPlaceholders["GT_INSTALL_CHANNEL"] = "chatflow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 安全加固：R8 混淆 + 资源收缩，降低被安全厂商灰度启发式误报的概率。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // KEYSTORE_FILE 环境变量可覆盖 storeFile 路径（CI 用仓库内
            // 相对路径；本地缺省保持 key.properties 的绝对路径行为）。
            val storeFilePath = System.getenv("KEYSTORE_FILE")
                ?.takeIf { it.isNotBlank() }
                ?: signingProperties.getProperty("storeFile")
            if (!storeFilePath.isNullOrBlank()) {
                signingConfigs.create("release") {
                    keyAlias = signingProperties.getProperty("keyAlias")
                    keyPassword = signingProperties.getProperty("keyPassword")
                    storeFile = file(storeFilePath)
                    storePassword = signingProperties.getProperty("storePassword")
                }
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // 桌面角标（PRD §35）：纯 Java 库，厂商启动器适配。
    implementation("me.leolin:ShortcutBadger:1.1.22")
    // 个推推送（scripts/GETUI_ANDROID_SDK_3.3.15.0 对应 Maven 坐标，固定版本）。
    // 隐私红线：客户端 manifest 仅含公开 AppID；AppKey/签名密钥只在
    // 服务端 getui-bridge 环境变量（docs/PUSH_SETUP.md）。
    implementation("com.getui:gtsdk:3.3.15.0")
    implementation("com.getui:gtc:3.3.3.0")
    implementation("com.getui:gsido:1.4.14.0")
    // 原生通话层 JVM 单测（PendingCallActions 冷启动动作暂存）。
    testImplementation(kotlin("test"))
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}



