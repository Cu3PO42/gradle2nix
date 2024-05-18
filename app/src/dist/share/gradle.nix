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

{
  # Path to the lockfile generated by gradle2nix (e.g. gradle.lock).
  lockFile
, pname ? "project"
, version ? null
, enableParallelBuilding ? true
# Arguments to Gradle used to build the project in buildPhase.
, gradleFlags ? [ "build" ]
# Enable debugging for the Gradle build; this will cause Gradle to run a debug server
# and wait for a JVM debugging client to attach.
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
, ... } @ args:

let
  inherit (builtins)
    attrValues concatStringsSep elemAt filter fromJSON getAttr hasAttr head length match
    removeAttrs replaceStrings sort;

  inherit (lib)
    assertMsg concatMapStringsSep findFirst foldl' groupBy' hasSuffix hasPrefix last mapAttrs
    mapAttrsToList optionalAttrs optionalString readFile removeSuffix unique versionAtLeast
    versionOlder;

  inherit (lib.strings) sanitizeDerivationName;

  lockedDeps = fromJSON (readFile lockFile);

  toCoordinates = id:
    let
      coords = builtins.split ":" id;
    in rec {
      group = elemAt coords 0;
      module = elemAt coords 2;
      version = elemAt coords 4;
      versionParts = parseVersion version;
    };

  parseVersion = version:
    let
      parts = builtins.split ":" version;
      base = elemAt parts 0;
    in
      {
        inherit base;
        exact = base;
      }
      // optionalAttrs (length parts >= 2) (
        let
          snapshot = elemAt parts 2;
          exact = replaceStrings [ "-SNAPSHOT" ] [ "-${snapshot}" ] base;
          parts = builtins.split "-" timestamp;
          timestamp = findFirst (match "[0-9]{8}\.[0-9]{6}") parts;
          buildNumber = let lastPart = last parts; in if match "[0-9]+" lastPart then lastPart else null;
        in
          { inherit snapshot exact timestamp buildNumber; }
      );

  fetchers' = {
    http = fetchurl;
    https = fetchurl;
  } // fetchers;

  # Fetch urls using the scheme for the first entry only; there isn't a
  # straightforward way to tell Nix to try multiple fetchers in turn
  # and short-circuit on the first successful fetch.
  fetch = name: { urls, hash }:
    let
      first = head urls;
      scheme = head (builtins.match "([a-z0-9+.-]+)://.*" first);
      fetch' = getAttr scheme fetchers';
      urls' = filter (hasPrefix scheme) urls;
    in
      fetch' { urls = urls'; inherit hash; };

  mkModule = id: artifacts:
    let
      coords = toCoordinates id;
      modulePath = "${replaceStrings ["."] ["/"] coords.group}/${coords.module}/${coords.version}";
    in
      stdenv.mkDerivation {
        pname = sanitizeDerivationName "${coords.group}-${coords.module}";
        version = coords.versionParts.exact;

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

  offlineRepo = symlinkJoin {
    name = if version != null then "${pname}-${version}-gradle-repo" else "${pname}-gradle-repo";
    paths = mapAttrsToList mkModule lockedDeps;
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

  buildProject = flags: ''
    gradle --offline --no-daemon --no-build-cache \
      --info --full-stacktrace --warning-mode=all \
      --no-configuration-cache \
      -Dmaven.repo.local=${offlineRepo} \
      ${optionalString enableParallelBuilding "--parallel"} \
      ${optionalString enableDebug "-Dorg.gradle.debug=true"} \
      ${optionalString (buildJdk != null) "-Dorg.gradle.java.home=${buildJdk.home}"} \
      --init-script ${initScript} \
      ${concatStringsSep " " flags}
  '';

in stdenv.mkDerivation ({

  dontStrip = true;

  nativeBuildInputs = (args.nativeBuildInputs or []) ++ [ gradle ];

  buildPhase = args.buildPhase or ''
    runHook preBuild

    (
    set -eux

    ${optionalString (versionOlder gradle.version "8.0") ''
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
      ${optionalString enableParallelBuilding "--parallel"} \
      ${optionalString enableDebug "-Dorg.gradle.debug=true"} \
      ${optionalString (buildJdk != null) "-Dorg.gradle.java.home=${buildJdk.home}"} \
      --init-script ${initScript} \
      ${concatStringsSep " " gradleFlags}
    )

    runHook postBuild
  '';

  passthru = (args.passthru or {}) // {
    inherit offlineRepo;
  };

} // (removeAttrs args [
  "nativeBuildInputs"
  "passthru"
  "lockFile"
  "gradleFlags"
  "gradle"
  "enableDebug"
  "extraInit"
  "buildJdk"
  "fetchers"
]))
