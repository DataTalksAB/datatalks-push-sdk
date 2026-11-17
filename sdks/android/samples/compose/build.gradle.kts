plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// google-services.json isn't in the repository. Without it the sample still builds, and registration logs why it fails.
if (file("google-services.json").exists()) {
    apply(plugin = libs.plugins.google.services.get().pluginId)
}

android {
    namespace = "se.datatalks.push.sample"
    compileSdk = 36

    defaultConfig {
        // Own package, so the sample installs next to the Data Talks app. The Firebase project's Android app and the push
        // app in the portal must both use this package.
        applicationId = "se.datatalks.sandbox"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // -PfidMode=true turns on Firebase FID registration, which invalidates the app's token for every sender.
        manifestPlaceholders["fidMode"] = (project.findProperty("fidMode") ?: "false").toString()
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":push"))
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
}
