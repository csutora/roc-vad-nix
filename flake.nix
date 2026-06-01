{
    description = "roc toolkit virtual audio device, packaged as a nix-darwin module";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        nix-teardown = {
            url = "github:csutora/nix-teardown";
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };

    outputs = { self, nixpkgs, nix-teardown }:
    let
        systems = [ "aarch64-darwin" "x86_64-darwin" ];
        forEachSystem = f:
            nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
        packages = forEachSystem (pkgs: rec {
            default = roc-vad;
            roc-vad = pkgs.callPackage ./package.nix {};
        });

        darwinModules.default = { config, lib, pkgs, ... }:
        let cfg = config.services.roc-vad; in {
            imports = [
                nix-teardown.darwinModules.default
                ./module.nix
            ];

            config = lib.mkIf cfg.enable {
                services.${nix-teardown.namespace}.entries = [
                    {
                        id = "https://github.com/csutora/roc-vad-nix";
                        cleanup = ''
                            if [ -x ${cfg.package}/bin/roc-vad ]; then
                                ${cfg.package}/bin/roc-vad device del -u nix-managed-sender 2>/dev/null || true
                            fi
                            rm -rf /Library/Audio/Plug-Ins/HAL/roc_vad.driver
                            rm -f /Library/Audio/Plug-Ins/HAL/.roc_vad.nixsrc
                            rm -rf /var/lib/roc-vad
                            launchctl kickstart -k system/com.apple.audio.coreaudiod || true
                        '';
                    }
                ];
            };
        };
    };
}
