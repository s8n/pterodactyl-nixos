# Wraps a NixOS system in a Docker image whose entrypoint is NixOS' stage-2
# init, which activates the system and execs systemd.
{
  dockerTools,
  nixos,
  name ? "pterodactyl-nixos",
  tag ? "latest",
}:

dockerTools.streamLayeredImage {
  inherit name tag;
  fakeRootCommands = ''
    mkdir -p tmp var run
    chmod 1777 tmp
    ln -s ${nixos.config.system.build.toplevel}/init init
  '';
  config = {
    Cmd = [ "/init" ];
    Env = [ "container=docker" ];
    # systemd shuts down cleanly on SIGRTMIN+3 rather than SIGTERM.
    StopSignal = "SIGRTMIN+3";
    ExposedPorts."80/tcp" = { };
    Volumes = {
      "/var/lib/mysql" = { };
      "/var/lib/pterodactyl-panel" = { };
    };
  };
}
