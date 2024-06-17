{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    android-nixpkgs.url = "github:tadfisher/android-nixpkgs";
    gradle2nix-flake.url =
      "github:expenses/gradle2nix/e54eff2fad6ef319e7d23b866900b3a1951bdbc7";
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
      android-sdk = android-nixpkgs.sdk.${system} (sdkPkgs:
        with sdkPkgs; [
          cmdline-tools-latest
          platform-tools
          platforms-android-33
          emulator
          ndk-bundle
          sdkPkgs.build-tools-30-0-3
        ]);

      pkgs = nixpkgs.legacyPackages.${system};

      crane-lib = crane.mkLib pkgs;

      fenix-pkgs = fenix.packages.${system};

      rust-toolchain = with fenix-pkgs;
        combine [
          stable.cargo
          stable.rustc
          targets."aarch64-linux-android".stable.toolchain
          targets."armv7-linux-androideabi".stable.toolchain
          targets."i686-linux-android".stable.toolchain
          targets."x86_64-linux-android".stable.toolchain
        ];

      cargo-mobile2 = pkgs.callPackage ./nix/patched-cargo-mobile2.nix { };

      cargo-build = crane-lib.vendorCargoDeps { cargoLock = ./Cargo.lock; };

      cargo-home = pkgs.symlinkJoin {
        name = "cargo-home";
        paths = [ cargo-build "${cargo-mobile2}/share" ];
      };

      environment = {
        ANDROID_HOME = "${android-sdk}";
        NDK_HOME = "${android-sdk}/share/android-sdk/ndk-bundle";
        CARGO_HOME = "${cargo-home}";
      };

      make-cargo-config = cargo-toml: mobile-toml:
        pkgs.runCommand "cargo-config" {
          inherit (environment) ANDROID_HOME NDK_HOME;
          buildInputs = [
            cargo-mobile2
            rust-toolchain
            pkgs.git
            (pkgs.writeScriptBin "rustup" "echo")
          ];
        } ''
          ln -s ${cargo-toml} Cargo.toml
          ln -s ${mobile-toml} mobile.toml
          cargo-mobile init -yvv 
          mkdir $out
          mv .cargo $out
        '';

      cargo-config = make-cargo-config ./Cargo.toml ./mobile.toml;

      inherit (gradle2nix-flake.packages.${system}) gradle2nix;

      mkShellWithHook = hook:
        pkgs.mkShell {
          buildInputs = [ android-sdk cargo-mobile2 pkgs.openjdk gradle2nix ];
          inherit (environment) ANDROID_HOME NDK_HOME CARGO_HOME;
          NIX_LD = with pkgs;
            lib.fileContents "${stdenv.cc}/nix-support/dynamic-linker";
          shellHook = hook;
        };

      gradleLockPath = ./gen/android/gradle.lock;

      patch-lock-file = file: patches:
        let
          lock-attr = builtins.fromJSON (builtins.readFile file);
          patched-lock-attr = pkgs.lib.recursiveUpdate lock-attr patches;
        in pkgs.writeText "gradle.lock" (builtins.toJSON patched-lock-attr);

      patched-gradle-lock = patch-lock-file gradleLockPath {
        "commons-codec:commons-codec:1.10"."commons-codec-1.10.jar" = {
          url =
            "https://repo.maven.apache.org/maven2/commons-codec/commons-codec/1.10/commons-codec-1.10.jar";
          hash = "sha256-QkHfqU5xHUNfKaRgSj4t5cSqPBZeI70Ga+b8H8QwlWk=";
        };
      };
    in {
      devShells.${system} = {
        default = mkShellWithHook "";
        update = mkShellWithHook ''
          rm -rf gen
          cargo mobile init -yvv
        '';
        build = mkShellWithHook ''
          cargo android apk build
        '';
      };

      packages.${system} = {
        inherit cargo-mobile2 cargo-build cargo-config patched-gradle-lock;
      };
      test = with pkgs;
        with lib;
        let
          gradleLockPath = patched-gradle-lock;
          gradleLock = builtins.fromJSON (builtins.readFile gradleLockPath);

          patchJars = moduleFilter: artifactFilter: args: f:
            let
              modules = filterAttrs (name: _: moduleFilter name) gradleLock;

              artifacts = filterAttrs (name: _: artifactFilter name);

              patch = src: runCommand src.name args (f src);
            in mapAttrs (_: module: mapAttrs (_: _: patch) (artifacts module))
            modules;

          aapt2LinuxJars = optionalAttrs stdenv.isLinux (patchJars
            (hasPrefix "com.android.tools.build:aapt2:") # moduleFilter
            (hasSuffix "-linux.jar") # artifactFilter
            { # args to runCommand
              nativeBuildInputs = [ jdk autoPatchelfHook ];
              buildInputs = [ stdenv.cc.cc.lib ];
              dontAutoPatchelf = true;
            } (src: ''
              cp ${src} aapt2.jar
              jar xf aapt2.jar aapt2
              chmod +x aapt2
              autoPatchelf aapt2
              jar uf aapt2.jar aapt2
              cp aapt2.jar $out
              echo $out
            ''));
        in gradle2nix-flake.builders.${system}.buildGradlePackage rec {
          pname = "android-app";
          version = "1.0";
          lockFile = gradleLockPath;
          gradleBuildFlags = [ "build" "--stacktrace" "--info" ];
          src = ./.;
          nativeBuildInputs =
            (with pkgs; [ android-sdk rust-toolchain cargo-mobile2 ]);
          preBuild = ''
            mkdir -p .cargo
            cat ${cargo-config}/.cargo/config.toml > .cargo/config.toml
            cd gen/android
          '';
          postBuild = ''
            mkdir -p $out
            cp -r app/build/outputs/apk $out
          '';
          inherit (environment) ANDROID_HOME NDK_HOME CARGO_HOME;
          overrides = aapt2LinuxJars;
        };
    };
}
