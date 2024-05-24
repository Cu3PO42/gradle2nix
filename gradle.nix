# This file is generated by gradle2nix.
#
# Example usage (e.g. in default.nix):
#
#     with (import <nixpkgs> {});
#     let
#       buildGradle = callPackage ./gradle.nix {};
#     in
#       buildGradle {
#         lockFile = ./gradle.lock;
#
#         src = ./.;
#
#         gradleFlags = [ "installDist" ];
#
#         installPhase = ''
#           mkdir -p $out
#           cp -r app/build/install/myproject $out
#         '';
#       }

{ lib
, stdenv
, buildEnv
, fetchs3
, fetchurl
, gradle
, maven
, runCommandLocal
, symlinkJoin
, writeText
, writeTextDir
}:

let defaultGradle = gradle; in

{
  # Path to the lockfile generated by gradle2nix (e.g. gradle.lock).
  lockFile ? null
, pname ? "project"
, version ? null
, enableParallelBuilding ? true
# The Gradle package to use. Default is 'pkgs.gradle'.
, gradle ? defaultGradle
# Arguments to Gradle used to build the project in buildPhase.
, gradleFlags ? [ "build" ]
# Enable debugging for the Gradle build; this will cause Gradle to run
# a debug server and wait for a JVM debugging client to attach.
, enableDebug ? false
# Additional code to run in the Gradle init script (init.gradle).
, extraInit ? ""
# Override the default JDK used to run Gradle itself.
, buildJdk ? null
# Override functions which fetch dependency artifacts.
# Keys in this set are URL schemes such as "https" or "s3".
# Values are functions which take a dependency in the form
# `{ urls, hash }` and fetch into the Nix store. For example:
#
#   {
#     s3 = { name, urls, hash }: fetchs3 {
#       s3url = builtins.head urls;
#       # TODO This doesn't work without patching fetchs3 to accept SRI hashes
#       inherit name hash;
#       region = "us-west-2";
#       credentials = {
#         access_key_id = "foo";
#         secret_access_key = "bar";
#       };
#     };
#   }
, fetchers ? { }
# Overlays for dependencies in the offline Maven repository.
#
# Acceps an attrset of dependencies (usually parsed from 'lockFile'), and produces an attrset
# containing dependencies to merge into the final set.
#
# The attrset is of the form:
#
#   {
#      "${group}:${module}:${version}" = <derivation>;
#      # ...
#   }
#
# A dependency derivation unpacks multiple source files into a single Maven-style directory named
# "${out}/${groupPath}/${module}/${version}/", where 'groupPath' is the dependency group ID with dot
# characters ('.') replaced by the path separator ('/').
#
# Examples:
#
# 1. Add or replace a dependency with a single JAR file:
#
#    (_: {
#      "com.squareup.okio:okio:3.9.0" = fetchurl {
#        url = "https://repo.maven.apache.org/maven2/com/squareup/okio/okio/3.9.0/okio-3.9.0.jar";
#        hash = "...";
#        downloadToTemmp = true;
#        postFetch = "install -Dt $out/com/squareup/okio/okio/3.9.0/ $downloadedFile"
#      };
#    })
#
# 2. Remove a dependency entirely:
#
#    # This works because the result is filtered for values that are derivations.
#    (_: {
#      "org.apache.log4j:core:2.23.1" = null;
#    })
, overlays ? []
, ... } @ args:

let
  inherit (builtins)
    attrValues concatStringsSep elemAt filter fromJSON getAttr head length mapAttrs removeAttrs
    replaceStrings;

  inherit (lib)
    mapAttrsToList optionalString readFile versionAtLeast versionOlder;

  inherit (lib.strings) sanitizeDerivationName;

  toCoordinates = id:
    let
      coords = builtins.split ":" id;

      parseVersion = version:
        let
          parts = builtins.split ":" version;
          base = elemAt parts 0;
        in
          if length parts >= 2
          then
            let
              snapshot = elemAt parts 2;
            in
              replaceStrings [ "-SNAPSHOT" ] [ "-${snapshot}" ] base
          else
            base;

    in rec {
      group = elemAt coords 0;
      module = elemAt coords 2;
      version = elemAt coords 4;
      uniqueVersion = parseVersion version;
    };

  fetchers' = {
    http = fetchurl;
    https = fetchurl;
  } // fetchers;

  # Fetch urls using the scheme for the first entry only; there isn't a
  # straightforward way to tell Nix to try multiple fetchers in turn
  # and short-circuit on the first successful fetch.
  fetch = name: { url, hash }:
    let
      scheme = head (builtins.match "([a-z0-9+.-]+)://.*" url);
      fetch' = getAttr scheme fetchers';
    in
      fetch' { inherit url hash; };

  mkModule = id: artifacts:
    let
      coords = toCoordinates id;
      modulePath = "${replaceStrings ["."] ["/"] coords.group}/${coords.module}/${coords.version}";
    in
      stdenv.mkDerivation {
        pname = sanitizeDerivationName "${coords.group}-${coords.module}";
        version = coords.uniqueVersion;

        srcs = mapAttrsToList fetch artifacts;

        dontPatch = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        dontInstall = true;

        preUnpack = ''
          mkdir -p "$out/${modulePath}"
        '';

        unpackCmd = ''
          cp "$curSrc" "$out/${modulePath}/$(stripHash "$curSrc")"
        '';

        sourceRoot = ".";

        preferLocalBuild = true;
        allowSubstitutes = false;
      };

  # Intermediate dependency spec.
  #
  # We want to allow overriding dependencies via the 'dependencies' function,
  # so we pass an intermediate set that maps each Maven coordinate to the
  # derivation created with 'mkModule'. This allows users extra flexibility
  # to do things like patching native libraries with patchelf or replacing
  # artifacts entirely.
  lockedDependencies = final: if lockFile == null then {} else
    let
      lockedDependencySpecs = fromJSON (readFile lockFile);
    in mapAttrs mkModule lockedDependencySpecs;


  finalDependencies =
    let
      composedExtension = lib.composeManyExtensions overlays;
      extended = lib.extends composedExtension lockedDependencies;
      fixed = lib.fix extended;
    in
      filter lib.isDerivation (attrValues fixed);

  offlineRepo = symlinkJoin {
    name = if version != null then "${pname}-${version}-gradle-repo" else "${pname}-gradle-repo";
    paths = finalDependencies;
  };

  initScript =
    let
      inSettings = pred: script:
        optionalString pred (
          if versionAtLeast gradle.version "6.0" then ''
            gradle.beforeSettings {
              ${script}
            }
          '' else ''
            gradle.settingsEvaluated {
              ${script}
            }
          ''
        );
    in
      writeText "init.gradle" ''
        static def offlineRepo(RepositoryHandler repositories) {
            repositories.clear()
            repositories.mavenLocal {
                url 'file:${offlineRepo}'
                metadataSources {
                    gradleMetadata()
                    mavenPom()
                    artifact()
                }
            }
        }

        ${inSettings (versionAtLeast gradle.version "6.0") ''
          offlineRepo(it.buildscript.repositories)
        ''}

        ${inSettings true ''
            offlineRepo(it.pluginManagement.repositories)
        ''}

        gradle.projectsLoaded {
            allprojects {
                buildscript {
                    offlineRepo(repositories)
                }
            }
        }

        ${if versionAtLeast gradle.version "6.8"
          then ''
            gradle.beforeSettings {
                it.dependencyResolutionManagement {
                    offlineRepo(repositories)
                    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
                }
            }
          ''
          else ''
            gradle.projectsLoaded {
                allprojects {
                    offlineRepo(repositories)
                }
            }
          ''
        }

        ${extraInit}
      '';


  buildGradle = stdenv.mkDerivation (finalAttrs: {

    inherit buildJdk enableParallelBuilding enableDebug gradle gradleFlags pname version;

    dontStrip = true;

    nativeBuildInputs = [ finalAttrs.gradle ]
                        ++ lib.optional (finalAttrs.buildJdk != null) finalAttrs.buildJdk;

    buildPhase = ''
      runHook preBuild

      (
      set -eux

      ${optionalString (versionOlder finalAttrs.gradle.version "8.0") ''
        # Work around https://github.com/gradle/gradle/issues/1055
        TMPHOME="$(mktemp -d)"
        mkdir -p "$TMPHOME/init.d"
        export GRADLE_USER_HOME="$TMPHOME"
        cp ${initScript} $TMPHOME/
      ''}

      gradle --offline --no-daemon --no-build-cache \
        --info --full-stacktrace --warning-mode=all \
        --no-configuration-cache --console=plain \
        -Dmaven.repo.local=${offlineRepo} \
        ${optionalString finalAttrs.enableParallelBuilding "--parallel"} \
        ${optionalString finalAttrs.enableDebug "-Dorg.gradle.debug=true"} \
        ${optionalString (finalAttrs.buildJdk != null) "-Dorg.gradle.java.home=${finalAttrs.buildJdk.home}"} \
        --init-script ${initScript} \
        ${concatStringsSep " " finalAttrs.gradleFlags}
      )

      runHook postBuild
    '';

    passthru = {
      inherit offlineRepo;
    };
  } // removeAttrs args [
    "lockFile"
    "extraInit"
    "fetchers"
    "overlays"
  ]);

in
buildGradle