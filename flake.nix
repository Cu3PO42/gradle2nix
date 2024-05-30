{
  description = "Wrap Gradle builds with Nix";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (nixpkgs) lib;
      in
      {
        builders = rec {
          buildGradlePackage = pkgs.callPackage ./gradle.nix { };
          default = buildGradlePackage;
        };

        packages = rec {
          gradle2nix = pkgs.callPackage ./default.nix { };
          default = gradle2nix;
        };

        apps = rec {
          gradle2nix = {
            type = "app";
            program = lib.getExe self.packages.${system}.default;
          };

          default = gradle2nix;
        };

        formatter = pkgs.writeShellScriptBin "gradle2nix-fmt" ''
          fail=0
          ${lib.getExe pkgs.nixfmt-rfc-style} $@ || fail=1
          ${lib.getExe pkgs.ktlint} --relative -l warn -F || fail=1
          [ $fail -eq 0 ] || echo "Formatting failed." >&2
          exit $fail
        '';
      }
    );
}
