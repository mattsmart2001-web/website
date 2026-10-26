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
        versionCode = 2
        versionName = "1.1"
    }

    // Android refuses to update an app whose signature has changed, so a
    // sideloaded APK must be signed with the same key every single time or
    // every driver has to uninstall before taking a new version. A CI
    // runner's debug keystore is generated fresh per run, which would do
    // exactly that, so a release build signs with a keystore supplied
    // through the environment and nothing else.
    val keystorePath = System.getenv("GTEC_KEYSTORE_PATH")
    val haveKeystore = !keystorePath.isNullOrBlank() && file(keystorePath).exists()

    signingConfigs {
        if (haveKeystore) {
            create("gtec") {
                storeFile = file(keystorePath!!)
                storePassword = System.getenv("GTEC_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("GTEC_KEY_ALIAS") ?: "gtec"
                keyPassword = System.getenv("GTEC_KEY_PASSWORD")
                    ?: System.getenv("GTEC_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // No shrinking: the app is tiny and R8 stripping a reflective
            // path in the JSON or notification code is not worth the risk
            // for an APK people sideload and cannot easily update.
            isMinifyEnabled = false
            // Debug-signed when no keystore is configured, so a local build
            // still produces something installable for testing. Such a build
            // is deliberately NOT publishable: see the android job, which
            // refuses to release one.
            signingConfig = if (haveKeystore) signingConfigs.getByName("gtec")
                            else signingConfigs.getByName("debug")
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
