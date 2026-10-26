# NixOS configuration for the Docker test container. Boots systemd as PID 1
# and runs the panel with a local MariaDB, Redis and nginx.
{ lib, pkgs, ... }:

{
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
      # Test container only: this ends up world-readable in the Nix store.
      passwordFile = pkgs.writeText "pterodactyl-admin-password" "changeme123";
    };
  };
  services.nginx.virtualHosts.localhost.default = true;

  system.stateVersion = "26.05";
}
