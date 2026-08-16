allprojects {
    repositories {
        // Google Maven is not directly reachable in every supported build
        // environment. This mirror serves the same immutable coordinates.
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        mavenCentral()
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
