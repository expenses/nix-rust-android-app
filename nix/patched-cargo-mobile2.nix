{ cargo-mobile2 }:
cargo-mobile2.overrideAttrs (final: prev: {
  # Use `--set-default` instead of `--set` so that CARGO_HOME can be overwritten.
  preFixup = ''
    for bin in $out/bin/cargo-*; do
      wrapProgram $bin \
        --set-default CARGO_HOME "$out/share"
    done
  '';
  # Hacky patch to run cargo offline.
  patches = [ ./cargo-mobile2-offline.patch ];
})
