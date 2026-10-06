import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM 은 선택 기능이라 Firebase 설정 파일이 있을 때만 적용한다(없으면 푸시 없이 빌드)
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

/** flutter build/run 의 --dart-define 값(gradle 속성 dart-defines, base64 목록)을 읽는다. */
fun dartDefine(key: String): String? =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.map { String(Base64.getDecoder().decode(it)) }
        ?.firstOrNull { it.startsWith("$key=") }
        ?.substringAfter("=")
        ?.takeIf { it.isNotEmpty() }

/** release 서명 정보: android/key.properties(git 제외, 키 파일 경로·비밀번호). 없으면 빈 값 */
val keystoreProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

android {
    namespace = "app.challory.challory"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.challory.challory"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // Health Connect 클라이언트 최소 지원
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // --dart-define=KAKAO_NATIVE_APP_KEY=... 를 매니페스트 스킴(kakao{키})에도 쓴다
        manifestPlaceholders["kakaoNativeAppKey"] = dartDefine("KAKAO_NATIVE_APP_KEY") ?: "none"
    }

    signingConfigs {
        if (keystoreProps.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // android/key.properties(git 제외)가 있으면 release 키로, 없으면 debug 키로(로컬 확인용)
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

