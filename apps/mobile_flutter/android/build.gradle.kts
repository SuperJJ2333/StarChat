allprojects {
    buildscript {
        repositories {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            mavenCentral()
            gradlePluginPortal()
        }
        configurations.configureEach {
            resolutionStrategy.force("com.android.tools.build:gradle:8.5.1")
        }
    }
    repositories {
        // Google Maven is not directly reachable in every supported build
        // environment. This mirror serves the same immutable coordinates.
        maven { url = uri("https://maven.aliyun.com/repository/google") }
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
