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

// Android SDK 37 ships under the new minor-version platform layout
// (`platforms/android-37.0` with `AndroidVersion.ApiLevel=37.0`), while plugins
// such as flutter_secure_storage pin a major-only `compileSdk = 37`. AGP then
// looks for a platform literally named `android-37` and fails to resolve it.
// Pin every Android module that targets 37 to the installed 37.0 platform so
// the app and its plugins agree.
//
// This MUST be registered before the `evaluationDependsOn` block below, which
// forces subprojects to evaluate (afterEvaluate would then be too late).
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            androidExt.withGroovyBuilder {
                if (getProperty("compileSdk") == 37) {
                    setProperty("compileSdkMinor", 0)
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
