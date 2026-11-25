// android/app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.darian.dash"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.darian.dash"
        // 车机要求 Android 7.0 = API 24
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    // 用 release 直接出未签名可安装包（车机一般允许第三方 APK）
    signingConfigs {
        create("dash") {
            storeFile = file("dash.jks")
            storePassword = "darian123"
            keyAlias = "dash"
            keyPassword = "darian123"
        }
    }

    buildTypes {
        release {
            // 车机不需要混淆，保持可读性便于排查
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("dash")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-service:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
