{ stdenvNoCC, fetchurl, lib }:

stdenvNoCC.mkDerivation rec {
    pname = "roc-vad";
    version = "0.0.4";

    src = fetchurl {
        url = "https://github.com/roc-streaming/roc-vad/releases/download/v${version}/roc-vad.tar.bz2";
        hash = "sha256-76OrOACS3lVBYNwCFAcC0rT5qi3bUDzyuQYYzbyV4po=";
    };

    dontUnpack = true;
    dontStrip = true;
    dontPatchELF = true;
    dontFixup = true;

    installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        tar -xjf "$src" -C "$out"
        mkdir -p "$out/bin"
        mv "$out/usr/local/bin/roc-vad" "$out/bin/roc-vad"
        rm -rf "$out/usr"
        runHook postInstall
    '';

    meta = {
        description = "roc toolkit virtual audio device for macos";
        homepage = "https://github.com/roc-streaming/roc-vad";
        license = lib.licenses.mpl20;
        platforms = lib.platforms.darwin;
    };
}
