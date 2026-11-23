import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins { kotlin("multiplatform") version "2.4.20" }
repositories { mavenCentral() }

val core = layout.projectDirectory.dir("shared/aprs-core")
check(core.file("build.gradle.kts").asFile.isFile) {
    "Run git submodule update --init before building."
}

/**
 * aprs-core caps the APRS-IS filter at 160 characters (140 custom). APRSERJi's filter holds up to three range
 * circles plus an always-show list of 12 callsigns, so the core sources are compiled from a copy with only those
 * limits raised; APRS-IS accepts login lines up to about 510 characters. The submodule itself is never edited,
 * and the build stops if an upstream change moves the text being patched.
 */
val corePatches = mapOf(
    "commonMain/kotlin/org/aprsfoundation/core/AprsFilters.kt" to listOf(
        "custom.length <= 140" to "custom.length <= 420",
        "filter.length<=160" to "filter.length<=440",
    ),
    "commonMain/kotlin/org/aprsfoundation/core/AprsProtocol.kt" to listOf(
        "filter.length <= 160" to "filter.length <= 440",
    ),
    "commonTest/kotlin/org/aprsfoundation/core/AprsFiltersTest.kt" to listOf(
        "\"x\".repeat(140)" to "\"x\".repeat(420)",
    ),
)
val patchedCore = layout.buildDirectory.dir("patched-core").get().asFile
run {
    patchedCore.deleteRecursively()
    core.dir("src").asFile.copyRecursively(patchedCore)
    corePatches.forEach { (path, edits) ->
        val file = patchedCore.resolve(path)
        var text = file.readText()
        edits.forEach { (from, to) ->
            check(from in text) { "aprs-core changed: '$from' is no longer in $path. Update corePatches in build.gradle.kts." }
            text = text.replace(from, to)
        }
        file.writeText(text)
    }
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
            kotlin.srcDirs(patchedCore.resolve("commonMain/kotlin"), patchedCore.resolve("appleMain/kotlin"))
            dependencies {
                implementation("io.ktor:ktor-network:3.1.3")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
                implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")
            }
        }
        commonTest {
            kotlin.srcDir(patchedCore.resolve("commonTest/kotlin"))
            dependencies { implementation(kotlin("test")) }
        }
    }
}
