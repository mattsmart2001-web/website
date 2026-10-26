plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "uk.co.sparkstheory.gtec.reporter"
    compileSdk = 34

    defaultConfig {
        applicationId = "uk.co.sparkstheory.gtec.reporter"
        // 21 = Android 5. It was 24 (Android 7), on the reasoning that older
        // than that is a vanishing share of devices, which is true of devices
        // in general and not true of one driver holding the phone he owns. He
        // got "There was a problem parsing the package", which is what Android
        // 6 says when it cannot read the signature, and the app would have
        // refused to install anyway.
        //
        // Nothing in here needed API 24. The only call that did was the
        // notification builder, which now takes the pre-Oreo path below 26,
        // and that path was needed for Android 7 too.
        minSdk = 21
        targetSdk = 34
        versionCode = 3
        versionName = "1.2"
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
                // Detected in CI when it was never set, because a keystore
                // exported by Windows is aliased by something the owner did
                // not choose.
                keyAlias = System.getenv("GTEC_KEY_ALIAS")?.takeIf { it.isNotBlank() } ?: "gtec"
                keyPassword = System.getenv("GTEC_KEY_PASSWORD")
                    ?: System.getenv("GTEC_KEYSTORE_PASSWORD")
                // Both schemes, stated rather than inferred. Signature scheme
                // v2 arrived in Android 7, and an APK carrying only v2 cannot
                // be verified by anything older: the installer finds no
                // certificate it understands and reports a parse error, which
                // is exactly what a driver on Android 6 saw. The old JAR
                // signature is what those devices read.
                //
                // Adding v1 does not disturb anyone already running the app.
                // Android verifies the newest scheme it supports, so a 7+
                // phone still checks v2, against the same key as before.
                enableV1Signing = true
                enableV2Signing = true
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
