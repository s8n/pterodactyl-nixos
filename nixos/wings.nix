{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pterodactyl-wings;
  # The panel module may not be imported at all.
  panelEnabled = config.services.pterodactyl-panel.enable or false;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkDefault
    literalExpression
    types
    ;

  yaml = pkgs.formats.yaml { };

  # Wings' default location, so `wings diagnostics` and friends find it too.
  configPath = "/etc/pterodactyl/config.yml";
  configFile = yaml.generate "wings-config.yml" cfg.settings;

  # A nested settings section: free-form, plus the options declared here.
  section =
    options:
    mkOption {
      default = { };
      type = types.submodule {
        freeformType = yaml.type;
        inherit options;
      };
    };
in
{
  options.services.pterodactyl-wings = {
    enable = mkEnableOption "Pterodactyl Wings, the daemon that runs game servers for Pterodactyl Panel";

    package = mkOption {
      type = types.package;
      default = pkgs.pterodactyl-wings;
      defaultText = literalExpression "pkgs.pterodactyl-wings";
      description = "The Wings package.";
    };

    tokenFile = mkOption {
      type = types.pathWith {
        inStore = false;
        absolute = true;
      };
      example = "/run/secrets/wings-token";
      description = ''
        File containing the node's `token`, the long secret from the node's
        Configuration tab in the panel. Wings (running as root) reads it at
        start; it never enters the Nix store.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the API port and the SFTP port in the firewall.";
    };

    settings = mkOption {
      default = { };
      description = ''
        Wings' `config.yml`. Copy `uuid`, `token_id` and `remote` from the
        node's Configuration tab in the panel; put the `token` into
        `tokenFile`. Anything else from upstream's configuration (see
        `config/config.go` in the Wings source) can be set here too.

        The file is written to `/etc/pterodactyl/config.yml` on every start of
        `pterodactyl-wings.service`, so changes Wings or the panel make to it
        do not last.
      '';
      example = literalExpression ''
        {
          uuid = "0b5a6e5d-3c43-4b41-9a2f-0e8f3c3f7a10";
          token_id = "Rk2dL7xQe9pZ1sYb";
          remote = "https://panel.example.com";
          api.ssl = {
            enabled = true;
            cert = "/var/lib/acme/node.example.com/fullchain.pem";
            key = "/var/lib/acme/node.example.com/key.pem";
          };
          allowed_mounts = [ "/srv/shared" ];
        }
      '';
      type = types.submodule {
        freeformType = yaml.type;
        options = {
          uuid = mkOption {
            type = types.str;
            description = "The node's UUID, from the panel.";
          };
          token_id = mkOption {
            type = types.str;
            description = "The node's token ID, from the panel. Not secret on its own.";
          };
          remote = mkOption {
            type = types.str;
            description = ''
              URL of the panel. Defaults to the panel's `APP_URL` when
              `services.pterodactyl-panel` is enabled on this machine.
            '';
          };
          api = section {
            port = mkOption {
              type = types.port;
              default = 8080;
              description = "Port of the HTTP API and websocket that the panel and browsers connect to.";
            };
          };
          system = section {
            root_directory = mkOption {
              type = types.str;
              default = "/var/lib/pterodactyl";
              description = "Wings' state directory: its database, server states, and by default the volumes, backups and archives.";
            };
            log_directory = mkOption {
              type = types.str;
              default = "/var/log/pterodactyl";
              description = "Directory for `wings.log` and server installation logs.";
            };
            username = mkOption {
              type = types.str;
              default = "pterodactyl-wings";
              description = ''
                System user that owns server files and that containers run as.
                The module creates it. Keep it different from the panel's user
                so the panel can't read server files.
              '';
            };
            timezone = mkOption {
              type = types.str;
              default = if config.time.timeZone != null then config.time.timeZone else "UTC";
              defaultText = literalExpression ''config.time.timeZone or "UTC"'';
              description = "Timezone passed to containers.";
            };
            sftp = section {
              bind_port = mkOption {
                type = types.port;
                default = 2022;
                description = "Port of the built-in SFTP server.";
              };
            };
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    services.pterodactyl-wings.settings = {
      # Wings expands file:// when it loads the configuration and writes it
      # back unexpanded, so the secret stays out of config.yml.
      token = "file://${cfg.tokenFile}";
      remote = mkIf panelEnabled (mkDefault config.services.pterodactyl-panel.settings.APP_URL);
      # The panel pushes node changes (ports, token, SSL) to Wings, which would
      # write them to config.yml only to have them replaced on the next start.
      # Change them here and in the panel instead.
      ignore_panel_config_updates = mkDefault true;
      # Upstream writes /etc/logrotate.d/wings; the module configures
      # services.logrotate instead.
      system.enable_log_rotate = mkDefault false;
    };

    virtualisation.docker.enable = true;

    users.users.${cfg.settings.system.username} = {
      isSystemUser = true;
      group = cfg.settings.system.username;
    };
    users.groups.${cfg.settings.system.username} = { };

    environment.systemPackages = [ cfg.package ];

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      cfg.settings.api.port
      cfg.settings.system.sftp.bind_port
    ];

    services.logrotate.settings.pterodactyl-wings = {
      files = "${cfg.settings.system.log_directory}/wings.log";
      size = "10M";
      compress = true;
      delaycompress = true;
      dateext = true;
      maxage = 7;
      missingok = true;
      notifempty = true;
      # Wings reopens its log file on SIGHUP.
      postrotate = "${config.systemd.package}/bin/systemctl kill -s HUP pterodactyl-wings.service";
    };

    systemd.services.pterodactyl-wings = {
      description = "Pterodactyl Wings";
      wantedBy = [ "multi-user.target" ];
      # Wings exits if it can't reach the panel at start; Restart covers a
      # panel that is still starting, the ordering covers a local one.
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      partOf = [ "docker.service" ];
      after = [
        "docker.service"
        "network-online.target"
      ]
      ++ lib.optionals panelEnabled [
        "pterodactyl-panel-setup.service"
        "phpfpm-pterodactyl-panel.service"
        "nginx.service"
      ];
      startLimitIntervalSec = 180;
      startLimitBurst = 30;
      serviceConfig = {
        # Wings needs root: it talks to Docker and chowns server files.
        ExecStartPre = "${pkgs.coreutils}/bin/install -D -m 0600 ${configFile} ${configPath}";
        ExecStart = "${lib.getExe cfg.package} --config ${configPath}";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 4096;
      };
    };
  };
}
