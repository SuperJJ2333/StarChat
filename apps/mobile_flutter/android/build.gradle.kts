allprojects {
    buildscript {
        repositories {
            // 阿里云镜像优先（国内构建环境），官方源回退（海外 CI：
            // 镜像偶发 502 时 gradle 依序回落，2026-09-04 Actions 首跑教训）。
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            google()
            mavenCentral()
            gradlePluginPortal()
        }
        configurations.configureEach {
            resolutionStrategy.force("com.android.tools.build:gradle:8.5.1")
        }
    }
    repositories {
        // 阿里云镜像优先（国内），google()/mavenCentral() 回退（海外 CI）。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        google()
        mavenCentral()
        // 个推推送 SDK（固定版本；仅 Android 客户端离线唤醒通道）。
        maven { url = uri("https://mvn.getui.com/nexus/content/repositories/releases/") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Pinned Flutter plugins may declare an older compile SDK than their
    // resolved AndroidX graph. Align every Android library plugin with the
    // application without editing the immutable Pub cache.
    afterEvaluate {
        extensions.findByType<com.android.build.api.dsl.LibraryExtension>()
            ?.compileSdk = 36
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
