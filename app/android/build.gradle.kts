import com.android.build.gradle.LibraryExtension
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

buildscript {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    // Makes AGP/KGP types visible so legacy plugin builds below can be
    // pinned to one JVM target. Versions match settings.gradle.kts.
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
    }
}

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
    if (project.projectDir.toPath().root == rootProject.projectDir.toPath().root) {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
    if (project.path != ":app") {
        tasks.matching { it.name.contains("Test", ignoreCase = true) }.configureEach {
            enabled = false
        }
    }
}

// Force legacy Groovy-style plugin builds onto one JVM target. withPlugin
// hooks run during evaluation, before compile options are finalized.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        val ext = extensions.getByType(LibraryExtension::class.java)
        ext.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
        ext.compileOptions.targetCompatibility = JavaVersion.VERSION_17
    }
    pluginManager.withPlugin("kotlin-android") {
        tasks.withType<KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17,
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
