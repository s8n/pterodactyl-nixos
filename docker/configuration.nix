# NixOS configuration for the Docker test container. Boots systemd as PID 1
# and runs the panel with a local MariaDB, Redis and nginx, plus Wings with
# its own Docker daemon, registered in the panel as a node.
{ lib, ... }:

{
  imports = [ ../tests/local-node.nix ];

  boot.isContainer = true;
  boot.postBootCommands = ''
    mkdir -p /run/systemd
    echo docker > /run/systemd/container
  '';

  networking.hostName = "pterodactyl";
  # Docker manages the network, /etc/hosts and /etc/resolv.conf.
  networking.useDHCP = false;
  networking.useHostResolvConf = lib.mkForce false;
  networking.firewall.enable = false;
  services.resolved.enable = false;
  # resolvconf would replace Docker's nameservers with an empty list.
  networking.resolvconf.enable = false;

  # Keep the image small.
  nix.enable = false;
  documentation.enable = false;
  environment.defaultPackages = [ ];

  time.timeZone = "Europe/Berlin";

  services.pterodactyl-panel = {
    enable = true;
    hostName = "localhost";
    settings = {
      # The port Docker publishes the container's port 80 on.
      APP_URL = "http://localhost:8080";
      APP_DEBUG = true;
      # Upstream ships shared reCAPTCHA keys; skip it for local testing.
      RECAPTCHA_ENABLED = false;
    };
    initialAdmin = {
      email = "admin@example.com";
      username = "admin";
      passwordFile = "/etc/pterodactyl-admin-password";
    };
  };
  # Test container only: secret options reject store paths, but the text of an
  # /etc file still ends up world-readable in the Nix store.
  environment.etc."pterodactyl-admin-password" = {
    text = "changeme123";
    mode = "0400";
  };
  services.nginx.virtualHosts.localhost.default = true;

  services.pterodactyl-wings = {
    enable = true;
    settings = {
      uuid = "0d3c7f4e-7b0c-4c39-9a51-3f6f1a2b9c01";
      token_id = "dockertestnode01";
      # Inside the container the panel is on port 80, not on APP_URL's port.
      remote = "http://localhost";
      allowed_origins = [ "http://localhost:8080" ];
      # Browsers connect to Wings directly, on the port Docker publishes.
      api.port = 8081;
      # The outer container takes 172.17.0.0/16, so the inner Docker's default
      # bridge moves to Wings' default 172.18.0.0/16.
      docker.network = {
        interface = "172.30.0.1";
        interfaces.v4 = {
          subnet = "172.30.0.0/16";
          gateway = "172.30.0.1";
        };
      };
    };
    tokenFile = "/etc/pterodactyl-wings-token";
  };
  environment.etc."pterodactyl-wings-token" = {
    text = "docker-test-token-0123456789abcdef0123456789abcdef0123456789ab";
    mode = "0400";
  };
  # Published by scripts/docker-test.
  pterodactyl-test.localNode.allocations = lib.range 25565 25569;

  system.stateVersion = "26.05";
}
