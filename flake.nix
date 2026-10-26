{
  description = "Pterodactyl Panel and Wings packaged for Nix, with NixOS modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # NixOS system that runs inside the Docker test container.
      dockerSystem =
        system:
        lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            ./docker/configuration.nix
          ];
        };
    in
    {
      overlays.default = final: _prev: {
        pterodactyl-panel = final.callPackage ./pkgs/pterodactyl-panel/package.nix { };
        pterodactyl-wings = final.callPackage ./pkgs/pterodactyl-wings/package.nix { };
      };

      nixosModules = {
        pterodactyl-panel =
          { lib, pkgs, ... }:
          {
            imports = [ ./nixos/module.nix ];
            services.pterodactyl-panel.package = lib.mkDefault (
              pkgs.callPackage ./pkgs/pterodactyl-panel/package.nix { }
            );
          };
        pterodactyl-wings =
          { lib, pkgs, ... }:
          {
            imports = [ ./nixos/wings.nix ];
            services.pterodactyl-wings.package = lib.mkDefault (
              pkgs.callPackage ./pkgs/pterodactyl-wings/package.nix { }
            );
          };
        default = {
          imports = [
            self.nixosModules.pterodactyl-panel
            self.nixosModules.pterodactyl-wings
          ];
        };
      };

      packages = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          pterodactyl-panel = pkgs.callPackage ./pkgs/pterodactyl-panel/package.nix { };
          pterodactyl-wings = pkgs.callPackage ./pkgs/pterodactyl-wings/package.nix { };
          default = self.packages.${system}.pterodactyl-panel;

          # A script that writes the test image to stdout: `$(nix build ... --print-out-paths) | docker load`
          docker-image = pkgs.callPackage ./docker/image.nix { nixos = dockerSystem system; };
        }
      );

      nixosConfigurations.docker-test = dockerSystem "x86_64-linux";

      checks = forAllSystems (pkgs: {
        vm-test = import ./tests/vm.nix { inherit self pkgs; };
      });

      # `nix fmt` with no arguments formats the .nix files in the current directory.
      formatter = forAllSystems (
        pkgs:
        pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = [
            pkgs.nixfmt
            pkgs.findutils
          ];
          text = ''
            if [ $# -eq 0 ]; then
              find . -name '*.nix' -not -path './.git/*' -exec nixfmt {} +
            else
              nixfmt "$@"
            fi
          '';
        }
      );
    };
}
