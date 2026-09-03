import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
            val storeFilePath = signingProperties.getProperty("storeFile")
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
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}



