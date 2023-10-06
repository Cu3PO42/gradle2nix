package org.nixos.gradle2nix

import io.kotest.core.spec.style.FunSpec

class GoldenTest : FunSpec({
    context("basic") {
        golden("basic/basic-java-project")
        golden("basic/basic-kotlin-project")
    }
    context("buildsrc") {
        golden("buildsrc/plugin-in-buildsrc")
    }
    context("dependency") {
        golden("dependency/classifier")
        golden("dependency/maven-bom")
        golden("dependency/snapshot")
        golden("dependency/snapshot-dynamic")
        golden("dependency/snapshot-redirect")
    }
    context("integration") {
        golden("integration/settings-buildscript")
    }
    context("ivy") {
        golden("ivy/basic")
    }
    context("plugin") {
        golden("plugin/resolves-from-default-repo")
    }
    context("s3") {
        golden("s3/maven")
        golden("s3/maven-snapshot")
    }
    context("settings") {
        golden("settings/buildscript")
        golden("settings/dependency-resolution-management")
    }
    context("subprojects") {
        golden("subprojects/multi-module")
    }
})