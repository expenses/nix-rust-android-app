{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    android-nixpkgs.url = "github:tadfisher/android-nixpkgs";
    gradle2nix-flake.url =
      "github:lunaticare/gradle2nix?ref=feature/build_android_app";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, android-nixpkgs, gradle2nix-flake, crane, fenix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      android-sdk = android-nixpkgs.sdk.${system} (sdkPkgs:
        with sdkPkgs; [
          cmdline-tools-latest
          build-tools-30-0-3
          platform-tools
          platforms-android-33
          emulator
          ndk-bundle
        ]);
      cargo-mobile2 = pkgs.cargo-mobile2.overrideAttrs (final: prev: {
        preFixup = ''
          for bin in $out/bin/cargo-*; do
            wrapProgram $bin \
              --set-default CARGO_HOME "$out/share"
          done
        '';
        patches = [ ./cargo-mobile2-offline.patch ];
      });
      inherit (gradle2nix-flake.packages.${system}) gradle2nix;
      # Vendor the cargo dependencies
      cargo-build = (crane.mkLib pkgs).vendorCargoDeps { src = ./.; };
      # Construct a fake home dir.
      cargo-home = pkgs.symlinkJoin {
        name = "cargo-home";
        paths = [ cargo-build "${cargo-mobile2}/share" ];
      };
      # Select the right toolchains
      rust-toolchain = with fenix.packages.${system};
        combine [
          stable.cargo
          stable.rustc
          targets."aarch64-linux-android".stable.toolchain
          targets."armv7-linux-androideabi".stable.toolchain
          targets."i686-linux-android".stable.toolchain
          targets."x86_64-linux-android".stable.toolchain
        ];

      mkShellWithHook = hook:
        pkgs.mkShell {
          buildInputs = [ android-sdk cargo-mobile2 pkgs.openjdk ];
          ANDROID_HOME = "${android-sdk}";
          NDK_HOME = "${android-sdk}/share/android-sdk/ndk-bundle";
          CARGO_HOME = "${cargo-home}";
          shellHook = hook;
        };
    in {
      devShells.${system} = {
        default = mkShellWithHook "";
        update = mkShellWithHook ''
          rm -rf gen
          cargo mobile init -yv
        '';
        build = mkShellWithHook ''
          cargo android apk build
        '';
      };
      hmm = with pkgs;
        stdenv.mkDerivation {
          name = "hmm";
          src = ./.;
          CARGO_HOME = "${cargo-home}";

          buildInputs = [ android-sdk pkgs.cargo-mobile2 pkgs.git ];
          buildCommand = ''
            cp -R $src/* .
            touch .first-init
            cargo-mobile init -yvv
          '';
        };
      test = gradle2nix-flake.builders.${system}.buildGradlePackage rec {
        pname = "android-app";
        version = "1.0";
        lockFile = ./gradle.lock;
        gradleFlags = [ "build" "--stacktrace" "--info" ];
        src = ./.;
        extraBuildInputs = [ ] ++ (with pkgs; [ rust-toolchain cargo-mobile2 ]);
        preBuild = ''
          cd gen/android
        '';
        postBuild = ''
          mkdir -p $out
          cp -r app/build/outputs/apk $out
        '';
        ANDROID_HOME = "${android-sdk}";
        NDK_HOME = "${android-sdk}/share/android-sdk/ndk-bundle";
        CARGO_HOME = "${cargo-home}";
      };
    };
}
