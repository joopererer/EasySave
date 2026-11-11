import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material lives outside this repository. Only Gradle reads it at build
// time: never log, echo or copy the file or any of its values.
val releaseKeyPropertiesFile: File =
    (System.getenv("EASYSAVE_KEY_PROPERTIES")?.takeIf { it.isNotBlank() })
        ?.let { File(it) }
        ?: File(System.getProperty("user.home"), ".easysave" + File.separator + "key.properties")

val releaseSigningProperties: Properties? = try {
    if (releaseKeyPropertiesFile.isFile) {
        Properties().apply { releaseKeyPropertiesFile.inputStream().use { load(it) } }
    } else {
        null
    }
} catch (_: Exception) {
    null
}

val resolveStoreFile: (Properties) -> File = { props ->
    val configured = props.getProperty("storeFile")?.trim().orEmpty()
    val candidate = File(configured)
    if (candidate.isAbsolute) candidate else File(releaseKeyPropertiesFile.parentFile, configured)
}

val releaseSigningProblems: List<String> = buildList {
    val props = releaseSigningProperties
    if (props == null) {
        add(
            "没有找到发布签名配置文件：" + releaseKeyPropertiesFile.absolutePath +
                "（可用环境变量 EASYSAVE_KEY_PROPERTIES 覆盖此路径）",
        )
    } else {
        listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { field ->
            if (props.getProperty(field).isNullOrBlank()) add("发布签名配置缺少字段：$field")
        }
        if (isEmpty() && !resolveStoreFile(props).isFile) {
            add("发布签名配置的 storeFile 指向的密钥文件不存在：" + resolveStoreFile(props).absolutePath)
        }
    }
}

android {
    namespace = "com.james.easysave"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (core library desugaring).
        isCoreLibraryDesugaringEnabled = true
    }

    dependencies {
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
        implementation("androidx.exifinterface:exifinterface:1.4.1")
        implementation("androidx.documentfile:documentfile:1.0.1")
        // Match video_player_android 2.9.5; never ship a second Media3 version.
        implementation("androidx.media3:media3-exoplayer:1.9.2")
        testImplementation("junit:junit:4.13.2")
        testImplementation("org.json:json:20240303")
        testImplementation("org.robolectric:robolectric:4.14.1")
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    testOptions { unitTests.isIncludeAndroidResources = true }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.james.easysave"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            releaseSigningProperties?.let { props ->
                storeFile = resolveStoreFile(props)
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
                props.getProperty("storeType")?.takeIf { it.isNotBlank() }?.let { storeType = it }
            }
        }
    }

    buildTypes {
        release {
            // Every delivered APK must be release-signed so upgrades keep installing over
            // each other. Never fall back to the debug keystore.
            signingConfig = signingConfigs.getByName("release")
        }
    }

    lint {
        disable += "FullBackupContent"
    }
}

// 发布构建必须在配置缺失时报错，绝不静默回退调试签名。
val requireReleaseSigning = tasks.register("requireReleaseSigning") {
    group = "verification"
    description = "Ensure EasySave release signing configuration is present before a release build."
    doLast {
        val problems = releaseSigningProblems
        if (problems.isNotEmpty()) {
            throw GradleException(
                "EasySave release 构建缺少发布签名配置，已停止构建：\n" +
                    problems.joinToString("\n") { "  - $it" } +
                    "\n请在 $releaseKeyPropertiesFile 配置 storeFile、storePassword、keyAlias、keyPassword，" +
                    "或通过环境变量 EASYSAVE_KEY_PROPERTIES 指向该配置文件。" +
                    "未找到配置文件时，release 构建必须失败，不得回退到调试密钥签名。"
            )
        }
    }
}

val releaseBuildTasks =
    tasks.matching { it.name == "preReleaseBuild" || it.name == "preBundleReleaseBuild" }
releaseBuildTasks.configureEach { dependsOn(requireReleaseSigning) }

flutter {
    source = "../.."
}
