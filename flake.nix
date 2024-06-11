{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    android-nixpkgs.url = "github:tadfisher/android-nixpkgs";
    gradle2nix-flake.url =
      "github:lunaticare/gradle2nix?ref=feature/build_android_app";
  };

  outputs = { self, nixpkgs, android-nixpkgs, gradle2nix-flake }:
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
      });
      inherit (gradle2nix-flake.packages.${system}) gradle2nix;
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ android-sdk gradle2nix cargo-mobile2 pkgs.openjdk ];
        ANDROID_HOME = "${android-sdk}";
        NDK_HOME = "${android-sdk}/share/android-sdk/ndk-bundle";
        shellHook = ''
          ln -s ${cargo-mobile2}/share/.cargo-mobile2 ~/.cargo/.cargo-mobile2
          export CARGO_HOME=~/.cargo
        '';
      };
    };
}
