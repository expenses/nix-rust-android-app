{ cargo-mobile2 }:
cargo-mobile2.overrideAttrs (final: prev: {
  preFixup = ''
    for bin in $out/bin/cargo-*; do
      wrapProgram $bin \
        --set-default CARGO_HOME "$out/share"
    done
  '';
  patches = [ ./cargo-mobile2-offline.patch ];
})
