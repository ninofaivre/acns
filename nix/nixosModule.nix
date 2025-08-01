{ acnsSystemPkgs, toZon }:
{ config, lib, pkgs, ... }:
let
  acnsPkgs = acnsSystemPkgs.${pkgs.stdenv.hostPlatform.system};
  cfg = config.services.acns;
  zonConfigContent = toZon {
    value = (cfg.settings // {
      socketPath = "acns.sock";
      socketGroupName = cfg.unixSocketAccessGroupName;
    });
  };
  configFile = pkgs.writeTextFile {
    name = "config.zon";
    text = zonConfigContent;
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
    unixSocketAccessGroupName = mkOption {
      type = types.str;
      description = ''
        this group will be added to SupplementaryGroups of the systemd unit
        and will own the rights to the socket in /run/acns
      '';
    };
    settings = mkOption {
      type = types.attrsOf types.anything;
    };
  };
  config = lib.mkIf cfg.enable {
    # TODO autogenerate group name like : acnsAccess followed by
    # instanceName (ex : kresd) : ex : acnsAccessKresd
    # TODO do a second group fot the ack socket : kresdAccessAcns
    users.groups.${cfg.unixSocketAccessGroupName} = {};
    environment.etc.${etcRelativeConfigPath} = lib.mkIf cfg.enableReload {
      source = configFile;
    };
    systemd.services.acns = {
      restartIfChanged = true;
      reloadTriggers = [ configFile ];
      enable = cfg.enable;
      serviceConfig = {
        RuntimeDirectory = [ "acns" ];
        RuntimeDirectoryMode = "0771";
        WorkingDirectory = "/run/acns";
        ExecStart = "${lib.getExe acnsPkgs.acns} -c ${configFilePath}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        DynamicUser = true;
        SupplementaryGroups = [ cfg.unixSocketAccessGroupName ];
        CapabilityBoundingSet = "CAP_NET_ADMIN";
        AmbientCapabilities = "CAP_NET_ADMIN";
      };
    };
  };
}
