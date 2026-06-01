{ config, lib, pkgs, ... }:

let
    cfg = config.services.roc-vad;
    s = cfg.sender;

    schemes = {
        rs8m = { source = "rtp+rs8m"; repair = "rs8m"; };
        ldpc = { source = "rtp+ldpc"; repair = "ldpc"; };
        disable = { source = "rtp"; repair = null; };
        default = { source = "rtp+rs8m"; repair = "rs8m"; };
    };
    scheme = schemes.${s.fec};

    sourceUri = "${scheme.source}://${s.remote.host}:${toString s.remote.sourcePort}";
    repairUri =
        if scheme.repair == null then null
        else "${scheme.repair}://${s.remote.host}:${toString s.remote.repairPort}";
    controlUri = "rtcp://${s.remote.host}:${toString s.remote.controlPort}";

    managedUid = "nix-managed-sender";

    optStr = x: if x == null then "<unset>" else x;

    specStr = lib.concatStringsSep "|" (map optStr [
        s.name
        s.fec
        s.resamplerProfile
        s.latencyProfile
        s.targetLatency
    ]);
    specHash = builtins.hashString "sha256" specStr;

    connectStr = lib.concatStringsSep "|" [
        sourceUri
        (optStr repairUri)
        controlUri
    ];
    connectHash = builtins.hashString "sha256" connectStr;

    mkFlag = flag: val:
        lib.optionalString (val != null) "${flag} ${lib.escapeShellArg val}";
in
{
    options.services.roc-vad = {
        enable = lib.mkEnableOption "roc-vad coreaudio audio bridge";

        package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.callPackage ./package.nix {};
            description = "roc-vad bundle plus cli package.";
        };

        sender = {
            enable = lib.mkEnableOption "auto-provisioned roc-vad sender device";

            name = lib.mkOption {
                type = lib.types.str;
                default = "sender";
                description = "human-readable device name shown in audio midi setup.";
            };

            remote = {
                host = lib.mkOption {
                    type = lib.types.str;
                    description = "remote receiver host (ip or dns name).";
                };

                sourcePort = lib.mkOption {
                    type = lib.types.port;
                    default = 10001;
                    description = "remote rtp source port. matches receiver local.source.port.";
                };

                repairPort = lib.mkOption {
                    type = lib.types.port;
                    default = 10002;
                    description = "remote fec repair port. matches receiver local.repair.port.";
                };

                controlPort = lib.mkOption {
                    type = lib.types.port;
                    default = 10003;
                    description = "remote rtcp control port. matches receiver local.control.port.";
                };
            };

            fec = lib.mkOption {
                type = lib.types.enum [ "disable" "default" "rs8m" "ldpc" ];
                default = "rs8m";
                description = "fec encoding. must match the receiver's fec setting.";
            };

            resamplerProfile = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "high" "medium" "low" ]);
                default = null;
                description = "resampler profile. when null, roc-vad picks the toolkit default.";
            };

            latencyProfile = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "intact" "responsive" "gradual" ]);
                default = null;
                description = "latency tuner profile. when null, roc-vad picks the toolkit default.";
            };

            targetLatency = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "60ms";
                description = "target end-to-end latency (duration string). when null, roc-vad uses its built-in default.";
            };
        };
    };

    config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        system.activationScripts.postActivation.text = ''
            (
                set -eu

                src=${cfg.package}/Library/Audio/Plug-Ins/HAL/roc_vad.driver
                dst=/Library/Audio/Plug-Ins/HAL/roc_vad.driver
                marker=/Library/Audio/Plug-Ins/HAL/.roc_vad.nixsrc

                changed=0
                if [ ! -e "$dst" ] || [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$src" ]; then
                    rm -rf "$dst"
                    mkdir -p /Library/Audio/Plug-Ins/HAL
                    cp -pR "$src" "$dst"
                    chown -R root:wheel "$dst"
                    printf '%s' "$src" > "$marker"
                    changed=1
                fi

                if [ "$changed" = "1" ]; then
                    killall -9 coreaudiod 2>/dev/null || true
                    sleep 2
                fi
            '' + lib.optionalString cfg.sender.enable ''

                ready=0
                attempt=0
                while [ "$attempt" -lt 30 ]; do
                    if ${cfg.package}/bin/roc-vad info >/dev/null 2>&1; then
                        ready=1
                        break
                    fi
                    attempt=$((attempt + 1))
                    sleep 1
                done

                if [ "$ready" != "1" ]; then
                    echo "roc-vad: timed out waiting for grpc server on 127.0.0.1:9712; skipping sender device setup" >&2
                else
                    mkdir -p /var/lib/roc-vad
                    spec_file=/var/lib/roc-vad/sender-spec.sha256
                    connect_file=/var/lib/roc-vad/sender-connect.sha256

                    spec_hash=${specHash}
                    connect_hash=${connectHash}
                    prev_spec=$(cat "$spec_file" 2>/dev/null || true)
                    prev_connect=$(cat "$connect_file" 2>/dev/null || true)

                    exists=0
                    if ${cfg.package}/bin/roc-vad device show -u ${lib.escapeShellArg managedUid} >/dev/null 2>&1; then
                        exists=1
                    fi

                    if [ "$spec_hash" != "$prev_spec" ] || [ "$exists" = "0" ]; then
                        if [ "$exists" = "1" ]; then
                            ${cfg.package}/bin/roc-vad device del -u ${lib.escapeShellArg managedUid}
                        fi
                        ${cfg.package}/bin/roc-vad device add sender \
                            --uid ${lib.escapeShellArg managedUid} \
                            --name ${lib.escapeShellArg s.name} \
                            --fec-encoding ${lib.escapeShellArg s.fec} \
                            ${mkFlag "--resampler-profile" s.resamplerProfile} \
                            ${mkFlag "--latency-profile" s.latencyProfile} \
                            ${mkFlag "--target-latency" s.targetLatency}
                        printf '%s' "$spec_hash" > "$spec_file"
                        rm -f "$connect_file"
                        prev_connect=""
                    fi

                    if [ "$connect_hash" != "$prev_connect" ]; then
                        ${cfg.package}/bin/roc-vad device connect -u ${lib.escapeShellArg managedUid} \
                            --source ${lib.escapeShellArg sourceUri} ${lib.optionalString (repairUri != null) "--repair ${lib.escapeShellArg repairUri}"} \
                            --control ${lib.escapeShellArg controlUri}
                        printf '%s' "$connect_hash" > "$connect_file"
                    fi
                fi
            '' + ''
            ) || echo "[roc-vad] activation failed" >&2
        '';
    };
}
