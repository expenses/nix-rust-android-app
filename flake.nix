{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    android-nixpkgs.url = "github:HPRIOR/android-nixpkgs";
    gradle2nix-flake.url = "github:expenses/gradle2nix/overrides-fix";
    flake-utils.url = "github:numtide/flake-utils";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, android-nixpkgs, gradle2nix-flake, crane, fenix
    , flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        build-tools-version = "30.0.3";
        android-sdk = android-nixpkgs.sdk.${system} (sdkPkgs:
          with sdkPkgs; [
            cmdline-tools-latest
            platform-tools
            platforms-android-33
            emulator
            ndk-bundle
            sdkPkgs.build-tools-30-0-3
          ]);

        build-tools-dir =
          "${android-sdk}/share/android-sdk/build-tools/${build-tools-version}";

        pkgs = nixpkgs.legacyPackages.${system};

        rust-targets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "i686-linux-android"
          "x86_64-linux-android"
        ];

        rust-toolchain = with fenix.packages.${system};
          combine ([ stable.cargo stable.rustc ]
            ++ (builtins.map (target: targets.${target}.stable.toolchain)
              rust-targets));

        cargo-mobile2 = pkgs.callPackage ./nix/patched-cargo-mobile2.nix { };

        crane-lib = (crane.mkLib pkgs).overrideToolchain rust-toolchain;

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

        # Generates .cargo and gen.
        gen-cargo-mobile = cargo-toml: mobile-toml:
          pkgs.runCommand "cargo-config" {
            inherit (environment) ANDROID_HOME NDK_HOME;
            buildInputs = [
              cargo-mobile2
              rust-toolchain
              pkgs.git
              (pkgs.writeScriptBin "rustup" "echo")
            ];
          } ''
            # Needs to be owned by the build user for whatever reason
            cp ${cargo-toml} Cargo.toml
            chmod +w Cargo.toml
            ln -s ${mobile-toml} mobile.toml
            touch .first-init
            cargo-mobile init -yvv
            mkdir $out
            mv .cargo gen $out
          '';

        cargo-config = gen-cargo-mobile ./Cargo.toml ./mobile.toml;

        # Concat the config.toml from the vendored deps 
        crane-vendor-dir = with pkgs;
          runCommand "crane-vendor-dir" { } ''
            cp -r ${cargo-build} $out
            chmod +w $out/config.toml
            cat ${cargo-config}/.cargo/config.toml >> $out/config.toml
          '';

        inherit (gradle2nix-flake.packages.${system}) gradle2nix;

        mkShellWithHook = hook:
          pkgs.mkShell {
            buildInputs = [ android-sdk cargo-mobile2 pkgs.openjdk gradle2nix ];
            inherit (environment) ANDROID_HOME NDK_HOME CARGO_HOME;
            # Setup nix ld for running aapt2
            NIX_LD = with pkgs;
              lib.fileContents "${stdenv.cc}/nix-support/dynamic-linker";
            shellHook = hook;
          };

        gradleLockPath = ./gradle.lock;

        patch-lock-file = file: patches:
          let
            lock-attr = builtins.fromJSON (builtins.readFile file);
            patched-lock-attr = pkgs.lib.recursiveUpdate lock-attr patches;
          in pkgs.writeText "gradle.lock" (builtins.toJSON patched-lock-attr);

        patched-gradle-lock = patch-lock-file gradleLockPath {
          # This didn't make it's way into the lock file for whatever reason.
          # Todo: can this patch be done inside buildGradlePackage instead?
          "commons-codec:commons-codec:1.10"."commons-codec-1.10.jar" = {
            url =
              "https://repo.maven.apache.org/maven2/commons-codec/commons-codec/1.10/commons-codec-1.10.jar";
            hash = "sha256-QkHfqU5xHUNfKaRgSj4t5cSqPBZeI70Ga+b8H8QwlWk=";
          };
        };

        clean-src = with pkgs;
          lib.sourceFilesBySuffices (lib.cleanSource ./.) [ ".rs" ".toml" ];
      in {
        devShells = {
          default = mkShellWithHook "";
          init = mkShellWithHook "cp -rs ${cargo-config}/{.cargo,gen}";
          gen = mkShellWithHook "gradle2nix -p gen/android build -o .";
          build = mkShellWithHook "./gen/android/gradlew -p gen/android build";
          keygen = mkShellWithHook
            "keytool -genkey -v -keystore my-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias my-alias";
        };

        packages = rec {
          inherit cargo-mobile2 cargo-build cargo-config patched-gradle-lock
            crane-vendor-dir;
          apk = with pkgs;
            with lib;
            let
              gradleLock =
                builtins.fromJSON (builtins.readFile patched-gradle-lock);

              patchJars = moduleFilter: artifactFilter: args: f:
                let
                  modules = filterAttrs (name: _: moduleFilter name) gradleLock;

                  artifacts = filterAttrs (name: _: artifactFilter name);

                  patch = src: runCommand src.name args (f src);
                in mapAttrs
                (_: module: mapAttrs (_: _: patch) (artifacts module)) modules;

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
              lockFile = patched-gradle-lock;
              gradleBuildFlags = [ "build" "--stacktrace" "--info" ];
              src = clean-src;
              nativeBuildInputs = [ android-sdk rust-toolchain cargo-mobile2 ];
              preBuild = ''
                cp -rs ${cargo-config}/{.cargo,gen} .
                chmod -R +w gen .cargo
                cd gen/android
              '';
              postBuild = ''
                mv app/build/outputs/apk $out
              '';
              inherit (environment) ANDROID_HOME NDK_HOME CARGO_HOME;
              overrides = aapt2LinuxJars;
            };
          # https://developer.android.com/build/building-cmdline#sign_cmdline
          aligned = pkgs.runCommand "aligned.apk" { } ''
            ${build-tools-dir}/zipalign -f -v -p 4 ${apk}/universal/release/app-universal-release-unsigned.apk aligned.apk
            mv aligned.apk $out
          '';
          #signed = pkgs.runCommand "signed.apk" {} ''
          #  ${build-tools-dir}/apksigner sign --ks ${./my-release-key.jks} --ks-pass 'pass:password' --out $out ${aligned}
          #  ${build-tools-dir}/apksigner verify $out
          #'';
        };
      });
}
