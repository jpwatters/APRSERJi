import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins { kotlin("multiplatform") version "2.4.20" }
repositories { mavenCentral() }

val core = layout.projectDirectory.dir("shared/aprs-core")
check(core.file("build.gradle.kts").asFile.isFile) {
    "Run git submodule update --init before building."
}

kotlin {
    val framework = XCFramework("AprsCore")
    listOf(iosArm64(), iosSimulatorArm64(), iosX64(), macosArm64(), macosX64()).forEach { target ->
        target.compilations.getByName("main").cinterops.create("appleSqlite") {
            definitionFile.set(project.file("src/nativeInterop/cinterop/appleSqlite.def"))
        }
        target.binaries.framework {
            baseName = "AprsCore"
            isStatic = true
            framework.add(this)
        }
    }
    sourceSets {
        commonMain {
            kotlin.srcDirs(core.dir("src/commonMain/kotlin"), core.dir("src/appleMain/kotlin"))
            dependencies {
                implementation("io.ktor:ktor-network:3.1.3")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
                implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")
            }
        }
        commonTest {
            kotlin.srcDir(core.dir("src/commonTest/kotlin"))
            dependencies { implementation(kotlin("test")) }
        }
    }
}
