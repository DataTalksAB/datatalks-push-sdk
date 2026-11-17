import com.vanniktech.maven.publish.AndroidSingleVariantLibrary

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.maven.publish)
}

android {
    namespace = "se.datatalks.push"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SDK_VERSION", "\"${project.version}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                // spec/ at the repository root: the fixtures and the OpenAPI document.
                it.systemProperty("spec.dir", rootProject.projectDir.resolve("../../spec").absolutePath)
            }
        }
    }
}

kotlin {
    // Kotlin 2.0 metadata and standard library, which an app still compiling with Kotlin 1.9 can read (2.2's it can't).
    coreLibrariesVersion = "2.0.21"
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0)
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0)
    }
}

mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    coordinates(project.group.toString(), "push-android", project.version.toString())
    publishToMavenCentral(automaticRelease = true)
    // Maven Central needs signed artifacts. Builds without the key (local, the Capacitor bundle) stay unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }

    pom {
        name.set("Data Talks Push for Android")
        description.set("Push notifications sent with Data Talks: device registration, identity, rendering and engagement events.")
        inceptionYear.set("2026")
        url.set("https://github.com/DataTalksTeam/datatalks-push-sdk")
        licenses {
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("datatalks")
                name.set("Data Talks")
                url.set("https://datatalks.se")
            }
        }
        scm {
            url.set("https://github.com/DataTalksTeam/datatalks-push-sdk")
            connection.set("scm:git:https://github.com/DataTalksTeam/datatalks-push-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/DataTalksTeam/datatalks-push-sdk.git")
        }
    }
}

// The Capacitor plugin bundles the SDK in its own Maven repository: ./gradlew :push:publishMavenPublicationToCapacitorRepository
publishing {
    repositories {
        maven {
            name = "capacitor"
            url = rootProject.projectDir.resolve("../capacitor/android/maven").toURI()
        }
    }
}

dependencies {
    // api: RemoteMessage is part of the public API. An app on a newer version keeps its own.
    api(libs.firebase.messaging)
    implementation(libs.androidx.core)
    implementation(libs.androidx.work)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.truth)
    testImplementation(libs.snakeyaml)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.work.testing)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.truth)
    androidTestImplementation(libs.mockwebserver)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
