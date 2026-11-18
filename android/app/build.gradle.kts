plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.quillnative.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.quillnative.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        // IndieAuth client ID: the page that describes the app, as on iOS.
        buildConfigField("String", "QUILL_CLIENT_ID", "\"${providers.gradleProperty("quillClientId").getOrElse("https://caseyg.github.io/quill-native/")}\"")
        // GitHub OAuth app for Drafts on GitHub (device flow, no secret). Empty means token sign-in only.
        buildConfigField("String", "QUILL_GITHUB_CLIENT_ID", "\"${providers.gradleProperty("quillGitHubClientId").getOrElse("Ov23liDE6sAoVfVPqX5h")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.androidx.browser)
    implementation(libs.coil.compose)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.compose.ui.tooling)
}
