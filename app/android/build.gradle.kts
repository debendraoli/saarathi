allprojects {
    repositories {
        google()
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
}
subprojects {
    // Some plugins (e.g. flutter_webrtc) pull in AndroidX libs that require
    // compileSdk >= 34, but this Flutter version defaults plugin modules to 31.
    // Force every Android subproject to compile against a modern SDK.
    // Registered before evaluationDependsOn so it isn't added post-evaluation.
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            androidExt.withGroovyBuilder {
                "compileSdkVersion"(37)
            }
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
