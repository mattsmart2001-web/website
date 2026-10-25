plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "uk.co.sparkstheory.gtec.reporter"
    compileSdk = 34

    defaultConfig {
        applicationId = "uk.co.sparkstheory.gtec.reporter"
        // 24 = Android 7. Older than that is not worth supporting and is a
        // vanishing share of devices.
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // No shrinking: the app is tiny and R8 stripping a reflective
            // path in the JSON or notification code is not worth the risk
            // for an APK people sideload and cannot easily update.
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    // Nothing at runtime beyond the platform: org.json ships with Android,
    // and Salsa20 is hand-written, so the APK has no third-party code in it.
    testImplementation("junit:junit:4.13.2")
}
