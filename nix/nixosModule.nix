{ acnsSystemPkgs, toZon }:
{ config, lib, pkgs, ... }:
let
  acnsPkgs = acnsSystemPkgs.${pkgs.stdenv.hostPlatform.system};
  cfg = config.services.acns;
  configFile = pkgs.writeTextFile {
    name = "config.zon";
    text = toZon cfg.settings;
    checkPhase = lib.optionalString cfg.validateConfig ''
      cp $out config.zon
      ${lib.getExe acnsPkgs.acns} -c config.zon --validate
    '';
  };
  etcRelativeConfigPath = "acns/config.zon";
  configFilePath = if cfg.enableReload then
      "/etc/${etcRelativeConfigPath}"
    else
      configFile;
in
{
  options.services.acns = with lib; {
    enable = mkEnableOption "enable acns";
    enableReload = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Wether to reload instead of restart on config change.
        Config file will be in /etc/acns/conf.zon
      '';
    };
    validateConfig = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Wether to validate config at build time by starting acns with --validate flag
      '';
    };
    settings = {
      socketPath = mkOption {
        type = types.str;
        default = "acns.sock";
        description = ''
          path of the socket used by the dns to add ips to sets.
          if not absolute will be based on WorkingDirectory of the
          systemd unit which itself is the RuntimeDirectory so will default
          to /run/acns/acns.sock
        '';
      };
      socketGroupName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          this group will be added to SupplementaryGroups of the systemd unit
          and will own the rights to the socket in /run/acns
        '';
      };
      resetTimeout = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          wether to reset nftables timeout if the ip is already in the set
          **can add a little bit of overhead / latency**
        '';
      };
      timeoutKernelAcksInMs = mkOption {
        type = types.nullOr types.ints.u8;
        default = null;
        description = ''
          time to wait for the acks of the kernel in ms before erroring
          (should be instant / 0ms in most cases)
        '';
      };
      accessControl = let
        tables = mkOption {
          type = types.nullOr (types.attrsOf (types.listOf types.str));
          default = null;
          description = ''
            attrset of nft tables containing nft sets
          '';
        };
      in {
        enabled = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            whether or not to enable accessControl
          '';
        };
        inet = tables;
        ip = tables;
        ip6 = tables;
        arp = tables;
        bridge = tables;
        netdev = tables;
      };
    };
  };
  config = lib.mkIf cfg.enable {
    # TODO autogenerate group name like : acnsAccess followed by
    # instanceName (ex : kresd) : ex : acnsAccessKresd
    # TODO do a second group fot the ack socket : kresdAccessAcns
    users.groups = with cfg.settings; lib.optionalAttrs
      (socketGroupName != null) { ${socketGroupName} = {}; };
    environment.etc.${etcRelativeConfigPath} = lib.mkIf cfg.enableReload {
      source = configFile;
    };
    systemd.services.acns = {
      restartIfChanged = true;
      reloadTriggers = [ configFile ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        RuntimeDirectory = [ "acns" ];
        RuntimeDirectoryMode = "0771";
        WorkingDirectory = "/run/acns";
        ExecStart = "${lib.getExe acnsPkgs.acns} -c ${configFilePath}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        DynamicUser = true;
        SupplementaryGroups = with cfg.settings; lib.optional
          (socketGroupName != null) socketGroupName;
        CapabilityBoundingSet = "CAP_NET_ADMIN";
        AmbientCapabilities = "CAP_NET_ADMIN";
      };
    };
  };
}
