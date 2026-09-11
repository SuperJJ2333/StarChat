// Gradle 仅在 404（该仓库没有此构件）时才会尝试下一个仓库；镜像返回 5xx
// （阿里云偶发 502）会直接判定依赖解析失败，不发生依序回落——2026-09-04
// Actions 首跑 502 失败的真正根因。因此仓库顺序必须在构建开始前按环境
// 选定：GitHub Actions 跑在海外，官方源优先且不依赖阿里云；国内本地构建
// 保持镜像优先，官方源供 404 回落。
val officialRepositoriesFirst =
    providers.environmentVariable("GITHUB_ACTIONS").isPresent

allprojects {
    configurations.configureEach {
        // Pin integration_test's dynamic selectors to the resolved test stack.
        // Reproducible builds must not require Maven version-list refreshes.
        resolutionStrategy.force(
            "androidx.test:runner:1.3.0",
            "androidx.test:rules:1.2.0",
            "androidx.test.espresso:espresso-core:3.3.0",
        )
    }
    buildscript {
        repositories {
            if (officialRepositoriesFirst) {
                google()
                mavenCentral()
                gradlePluginPortal()
            } else {
                maven { url = uri("https://maven.aliyun.com/repository/google") }
                google()
                mavenCentral()
                gradlePluginPortal()
            }
        }
        configurations.configureEach {
            resolutionStrategy.force("com.android.tools.build:gradle:8.5.1")
        }
    }
    repositories {
        if (officialRepositoriesFirst) {
            google()
            mavenCentral()
        } else {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            google()
            mavenCentral()
        }
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
