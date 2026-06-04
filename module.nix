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

    boolStr = b: if b then "1" else "0";

    specStr = lib.concatStringsSep "|" (map optStr [
        s.name
        (toString s.deviceRate)
        s.deviceChans
        (optStr (if s.deviceTracks == null then null else toString s.deviceTracks))
        s.deviceBuffer
        (toString s.packetEncodingId)
        (toString s.packetEncodingRate)
        s.packetEncodingFormat
        s.packetEncodingChans
        (optStr (if s.packetEncodingTracks == null then null else toString s.packetEncodingTracks))
        s.packetLength
        (boolStr s.packetInterleaving)
        s.fec
        (optStr (if s.fecBlockNbsrc == null then null else toString s.fecBlockNbsrc))
        (optStr (if s.fecBlockNbrpr == null then null else toString s.fecBlockNbrpr))
        s.resamplerBackend
        s.resamplerProfile
        s.latencyBackend
        s.latencyProfile
        s.targetLatency
        s.latencyTolerance
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

            deviceRate = lib.mkOption {
                type = lib.types.ints.positive;
                default = 48000;
                example = 48000;
                description = ''
                    sample rate the virtual device exposes to coreaudio, in hertz.
                    defaults to 48000 to match macos' typical mixer rate.
                '';
            };

            deviceChans = lib.mkOption {
                type = lib.types.enum [ "mono" "stereo" "multitrack" ];
                default = "stereo";
                description = "virtual device channel layout.";
            };

            deviceTracks = lib.mkOption {
                type = lib.types.nullOr (lib.types.ints.between 1 1024);
                default = null;
                description = "track count when deviceChans = multitrack. range [1, 1024].";
            };

            deviceBuffer = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "60ms";
                description = "virtual device buffer size. when null, roc-vad uses its default (60ms).";
            };

            packetEncodingId = lib.mkOption {
                type = lib.types.ints.between 1 254;
                default =
                    let s = config.services.roc-vad.sender; in
                    if s.packetEncodingRate == 44100
                        && s.packetEncodingFormat == "s16"
                        && s.packetEncodingChans == "stereo"
                    then 10
                    else if s.packetEncodingRate == 44100
                        && s.packetEncodingFormat == "s16"
                        && s.packetEncodingChans == "mono"
                    then 11
                    else 100;
                description = ''
                    unique id for packet encoding, in [1; 254].

                    auto-defaults intelligently: id 10 if the rest of the encoding
                    is the roc-toolkit built-in AVP_L16_STEREO (44.1kHz s16 stereo),
                    id 11 for the built-in AVP_L16_MONO (44.1kHz s16 mono), or
                    100 for anything else (a custom encoding that gets registered
                    with roc-toolkit at activation time).

                    ids 10 and 11 cannot be reused with different specs. for any
                    custom encoding you must use an id outside {10, 11}.

                    must match the receiver's packet-encoding-id.
                '';
            };

            packetEncodingRate = lib.mkOption {
                type = lib.types.ints.positive;
                default = config.services.roc-vad.sender.deviceRate;
                description = ''
                    sample rate of the wire packet encoding, in hertz. defaults to
                    deviceRate so no internal resampling happens. must match the
                    receiver's packet-encoding-rate end to end.
                '';
            };

            packetEncodingFormat = lib.mkOption {
                type = lib.types.enum [ "s16" ];
                default = "s16";
                description = "sample format for packets. must match the receiver's packet-encoding-format.";
            };

            packetEncodingChans = lib.mkOption {
                type = lib.types.enum [ "mono" "stereo" "multitrack" ];
                default = config.services.roc-vad.sender.deviceChans;
                description = ''
                    channel layout for packets. defaults to deviceChans to avoid an
                    internal layout conversion. must match the receiver's
                    packet-encoding-chans.
                '';
            };

            packetEncodingTracks = lib.mkOption {
                type = lib.types.nullOr (lib.types.ints.between 1 1024);
                default = config.services.roc-vad.sender.deviceTracks;
                description = "track count for multitrack packet encoding. defaults to deviceTracks.";
            };

            packetLength = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "5ms";
                description = "audio packet length. when null, uses roc-vad's default (5ms).";
            };

            packetInterleaving = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "enable packet interleaving (higher loss tolerance, higher latency).";
            };

            fec = lib.mkOption {
                type = lib.types.enum [ "disable" "default" "rs8m" "ldpc" ];
                default = "rs8m";
                description = "fec encoding. must match the receiver's fec setting.";
            };

            fecBlockNbsrc = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "source packets per fec block. when null, uses roc-vad's default (18).";
            };

            fecBlockNbrpr = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "repair packets per fec block. when null, uses roc-vad's default (10).";
            };

            resamplerBackend = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "builtin" "speex" "speexdec" ]);
                default = null;
                description = "resampler backend. when null, roc-vad selects automatically.";
            };

            resamplerProfile = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "high" "medium" "low" ]);
                default = null;
                description = "resampler profile. when null, roc-vad uses its toolkit default.";
            };

            latencyBackend = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "niq" ]);
                default = null;
                description = ''
                    latency tuner backend. when null, sender-side latency tuning is
                    disabled (the typical setup; usually you want the receiver to do
                    the latency tuning).
                '';
            };

            latencyProfile = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [ "default" "intact" "responsive" "gradual" ]);
                default = null;
                description = "latency tuner profile. when null, sender-side latency tuning is disabled.";
            };

            targetLatency = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "60ms";
                description = "target end-to-end latency (duration string). when null, sender-side latency tuning is disabled.";
            };

            latencyTolerance = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "20ms";
                description = "maximum deviation of latency from target. when null, uses roc-vad's default.";
            };
        };
    };

    config = lib.mkIf cfg.enable {
        assertions = [
            {
                assertion = !cfg.sender.enable
                    || cfg.sender.packetEncodingId != 10
                    || (cfg.sender.packetEncodingRate == 44100
                        && cfg.sender.packetEncodingFormat == "s16"
                        && cfg.sender.packetEncodingChans == "stereo");
                message = ''
                    services.roc-vad.sender.packetEncodingId = 10 is reserved by
                    roc-toolkit for the built-in AVP_L16_STEREO encoding and can
                    only be used with rate=44100, format=s16, chans=stereo. for
                    a non-standard configuration, pick a different id (e.g. 100).
                '';
            }
            {
                assertion = !cfg.sender.enable
                    || cfg.sender.packetEncodingId != 11
                    || (cfg.sender.packetEncodingRate == 44100
                        && cfg.sender.packetEncodingFormat == "s16"
                        && cfg.sender.packetEncodingChans == "mono");
                message = ''
                    services.roc-vad.sender.packetEncodingId = 11 is reserved by
                    roc-toolkit for the built-in AVP_L16_MONO encoding and can
                    only be used with rate=44100, format=s16, chans=mono. for
                    a non-standard configuration, pick a different id (e.g. 100).
                '';
            }
        ];

        environment.systemPackages = [ cfg.package ];

        system.activationScripts.postActivation.text = ''
            (
                set -eu

                echo "Activating roc-vad"

                roc_vad() {
                    if ! out=$("${cfg.package}/bin/roc-vad" "$@" 2>&1); then
                        printf '%s\n' "$out" >&2
                        return 1
                    fi
                }

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
                            roc_vad device del -u ${lib.escapeShellArg managedUid}
                        fi
                        roc_vad device add sender \
                            --uid ${lib.escapeShellArg managedUid} \
                            --name ${lib.escapeShellArg s.name} \
                            --device-rate ${toString s.deviceRate} \
                            --device-chans ${lib.escapeShellArg s.deviceChans} \
                            ${lib.optionalString (s.deviceTracks != null) "--device-tracks ${toString s.deviceTracks}"} \
                            ${mkFlag "--device-buffer" s.deviceBuffer} \
                            ${lib.optionalString (s.packetEncodingId != 10 && s.packetEncodingId != 11) "--packet-encoding-id ${toString s.packetEncodingId} --packet-encoding-rate ${toString s.packetEncodingRate} --packet-encoding-format ${lib.escapeShellArg s.packetEncodingFormat} --packet-encoding-chans ${lib.escapeShellArg s.packetEncodingChans}"} \
                            ${lib.optionalString (s.packetEncodingId != 10 && s.packetEncodingId != 11 && s.packetEncodingTracks != null) "--packet-encoding-tracks ${toString s.packetEncodingTracks}"} \
                            ${mkFlag "--packet-length" s.packetLength} \
                            ${lib.optionalString s.packetInterleaving "--packet-interleaving"} \
                            --fec-encoding ${lib.escapeShellArg s.fec} \
                            ${lib.optionalString (s.fecBlockNbsrc != null) "--fec-block-nbsrc ${toString s.fecBlockNbsrc}"} \
                            ${lib.optionalString (s.fecBlockNbrpr != null) "--fec-block-nbrpr ${toString s.fecBlockNbrpr}"} \
                            ${mkFlag "--resampler-backend" s.resamplerBackend} \
                            ${mkFlag "--resampler-profile" s.resamplerProfile} \
                            ${mkFlag "--latency-backend" s.latencyBackend} \
                            ${mkFlag "--latency-profile" s.latencyProfile} \
                            ${mkFlag "--target-latency" s.targetLatency} \
                            ${mkFlag "--latency-tolerance" s.latencyTolerance}
                        printf '%s' "$spec_hash" > "$spec_file"
                        rm -f "$connect_file"
                        prev_connect=""
                    fi

                    if [ "$connect_hash" != "$prev_connect" ]; then
                        roc_vad device connect -u ${lib.escapeShellArg managedUid} \
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
