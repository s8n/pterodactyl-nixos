# pterodactyl-nixos

Nix packages and NixOS modules for [Pterodactyl](https://pterodactyl.io): Panel 1.15.2 and Wings 1.13.4.

- `pkgs/pterodactyl-panel/package.nix`: builds the panel from the upstream release tarball (frontend already compiled) with `buildComposerProject2` on PHP 8.3.
- `pkgs/pterodactyl-wings/package.nix`: builds Wings from source with `buildGoModule`.
- `nixos/module.nix`: `services.pterodactyl-panel`. Sets up PHP-FPM, nginx, the queue worker, the scheduler timer, database migrations, and by default a local MariaDB and Redis.
- `nixos/wings.nix`: `services.pterodactyl-wings`. Runs Wings and Docker.
- `docker/`: a NixOS system that boots with systemd inside a Docker container, for trying the modules out.
- `tests/vm.nix`: a NixOS VM test (`nix flake check`).

`nixosModules.default` imports both modules; `nixosModules.pterodactyl-panel` and `nixosModules.pterodactyl-wings` import one each. Panel and Wings can run on the same machine or on different ones.

## Usage

```nix
{
  inputs.pterodactyl.url = "git+file:///path/to/pterodactyl-nixos"; # or wherever you host it

  outputs = { nixpkgs, pterodactyl, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pterodactyl.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
{
  services.pterodactyl-panel = {
    enable = true;
    hostName = "panel.example.com";

    settings = {
      APP_TIMEZONE = "Europe/Berlin";
      MAIL_MAILER = "smtp";
      MAIL_HOST = "smtp.example.com";
      MAIL_PORT = 587;
      MAIL_USERNAME = "panel@example.com";
      MAIL_PASSWORD._secret = "/run/secrets/pterodactyl-smtp"; # read at runtime
      MAIL_FROM_ADDRESS = "panel@example.com";
    };

    initialAdmin = {
      email = "you@example.com";
      username = "admin";
      passwordFile = "/run/secrets/pterodactyl-admin";
    };
  };

  # TLS goes on the virtual host the module creates. APP_URL switches to
  # https:// automatically when forceSSL/onlySSL is set.
  services.nginx.virtualHosts."panel.example.com" = {
    forceSSL = true;
    enableACME = true;
  };
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "you@example.com";
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

Run artisan commands as the panel user with `pterodactyl-artisan`, for example `pterodactyl-artisan p:user:make` or `pterodactyl-artisan p:location:make`.

## Panel

### Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `hostName` | none | nginx virtual host and default `APP_URL`. |
| `settings` | see below | Written to `.env`. Any variable from upstream's `.env.example` / `config/*.php`. `{ _secret = "/path/to/file"; }` reads a value from a file at service start. Secret paths (here and in the `*File` options) must be absolute strings outside the Nix store, such as `"/run/secrets/..."`; path literals and store paths such as `pkgs.writeText` are rejected. |
| `appKeyFile`, `hashidsSaltFile` | `null` | If null, they are generated on first start into `${dataDir}/secrets/`. **Back up `app-key`**: without it, node tokens, database host passwords and 2FA secrets can't be decrypted. |
| `database.createLocally` | `true` | Local MariaDB over the Unix socket with socket auth, so no password is needed. Set to `false` and use `database.{host,port,name,user,passwordFile}` for an external database. |
| `redis.createLocally` | `true` | Dedicated Redis on a Unix socket, used for cache, sessions and the queue. |
| `initialAdmin` | `null` | Created once, on first start, unless a user with that email or username already exists. The password is read from `passwordFile`. |
| `enableNginx` | `true` | |
| `phpfpm.settings` | `{}` | Merged over the pool defaults (`pm = dynamic`, 16 children). |
| `queueWorker.extraArgs` | `[]` | Extra arguments for `artisan queue:work`. |
| `user`, `group`, `dataDir`, `package` | `pterodactyl`, `pterodactyl`, `/var/lib/pterodactyl-panel`, the flake's package | |

Defaults the module puts in `settings` (each can be overridden): `APP_ENV=production`, `APP_DEBUG=false`, `APP_ENVIRONMENT_ONLY=true`, `APP_TIMEZONE` = `time.timeZone` or UTC, `LOG_CHANNEL=daily`, `LOG_LEVEL=info`, `MAIL_MAILER=log`, plus the DB and Redis variables.

Things to know:

- `.env` is regenerated whenever `pterodactyl-panel-setup.service` starts, so changes made with `p:environment:*` commands don't last. Put them in `settings` instead.
- `APP_ENVIRONMENT_ONLY = true` (the default) turns off the settings pages in the admin area so that all configuration comes from Nix. Set it to `false` if you want to manage mail and similar settings from the UI.
- Upstream enables reCAPTCHA with shared public keys by default. To use your own keys, set `RECAPTCHA_WEBSITE_KEY` and `RECAPTCHA_SECRET_KEY`. To turn it off, set `RECAPTCHA_ENABLED = false`.
- Behind another reverse proxy, set `TRUSTED_PROXIES`.
- As with upstream's update procedure, the stock nests and eggs are re-seeded whenever the panel version changes, which overwrites edits made to them in the UI. A version bump can arrive through a routine `nix flake update`. To customise a stock egg, export it and import it as a new egg, then edit the copy.

### Services

| Unit | What it does |
|---|---|
| `pterodactyl-panel-setup.service` | Oneshot. Generates missing secrets, writes `.env`, clears compiled config and views, runs `migrate --force`, seeds nests and eggs when the panel version changes, creates the initial admin. Runs again when the package or settings change, so upgrades apply migrations automatically. |
| `phpfpm-pterodactyl-panel.service` | PHP-FPM pool. |
| `pterodactyl-panel-queue.service` | `artisan queue:work` (upstream calls this `pteroq`). |
| `pterodactyl-panel-scheduler.timer` | `artisan schedule:run` every minute. |

## Wings

Create a location and a node in the panel first (Admin → Locations, Admin → Nodes), then copy the values from the node's Configuration tab:

```nix
{
  services.pterodactyl-wings = {
    enable = true;
    settings = {
      uuid = "0b5a6e5d-3c43-4b41-9a2f-0e8f3c3f7a10"; # `uuid` from the panel
      token_id = "Rk2dL7xQe9pZ1sYb"; # `token_id`
      remote = "https://panel.example.com"; # not needed when the panel runs on this machine
    };
    tokenFile = "/run/secrets/wings-token"; # contains `token`
    openFirewall = true; # API (8080) and SFTP (2022)
  };
}
```

The panel's Configuration tab also lists API port, SFTP port, upload limit and SSL settings. The module's defaults match the panel's defaults (8080, 2022, no SSL). If you change one on either side, change it on the other too.

For TLS, either enable `api.ssl` in `settings` with a certificate Wings can read (it runs as root, so `security.acme` certificates work), or put Wings behind a reverse proxy, set the node's "Behind Proxy" option in the panel and keep `api.ssl` off. Browsers connect to Wings directly for the console and file uploads, so a panel served over HTTPS needs Wings on HTTPS too.

Game server ports are allocations: you create them in the panel, and Docker publishes them on the host.

### Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | Also enables `virtualisation.docker`. |
| `tokenFile` | none | File containing the node's `token`. Same rules as the panel's secret paths. |
| `openFirewall` | `false` | Opens `settings.api.port` and `settings.system.sftp.bind_port`. |
| `settings` | see below | Wings' `config.yml`. Anything from upstream's `config/config.go`. |
| `package` | the flake's package | |

Defaults the module puts in `settings`: `remote` = the panel's `APP_URL` if `services.pterodactyl-panel` is enabled on the same machine, `api.port = 8080`, `system.sftp.bind_port = 2022`, `system.root_directory = /var/lib/pterodactyl`, `system.log_directory = /var/log/pterodactyl`, `system.timezone` = `time.timeZone` or UTC, `system.username = "pterodactyl-wings"` (a system user the module creates; server files belong to it), `system.enable_log_rotate = false` (the module configures `services.logrotate` instead), `ignore_panel_config_updates = true`, and `token = "file://<tokenFile>"`.

Things to know:

- `/etc/pterodactyl/config.yml` is regenerated whenever `pterodactyl-wings.service` starts. It holds a `file://` reference to `tokenFile`, not the token itself. Because the file is in the default location, `wings diagnostics` works without arguments.
- `ignore_panel_config_updates` is on because the panel pushes node edits (ports, SSL, a reset token) straight into Wings' `config.yml`, and the module would overwrite them on the next restart. Make those changes in Nix and in the panel. If you reset the node's token in the panel, update `tokenFile` and restart Wings.
- Wings exits if it can't reach the panel when it starts. systemd restarts it after 5 seconds, and gives up after 30 failed starts within 3 minutes. When the panel is on the same machine, Wings starts after it.
- Wings creates a Docker network, `pterodactyl_nw`, on `172.18.0.0/16`. If that range is already used on your network, set `docker.network.interface` and `docker.network.interfaces.v4.{subnet,gateway}` in `settings`.

### Services

| Unit | What it does |
|---|---|
| `pterodactyl-wings.service` | Writes `config.yml`, then runs Wings as root (it manages Docker and owns server files). Requires `docker.service`. |

## Trying it in Docker

You don't need Nix on the host: `scripts/nix` runs Nix inside the `nixos/nix` image and keeps its store in the `pterodactyl-nix-store` Docker volume.

The container runs the panel and Wings. Wings is already registered as a node called `local`, with allocations on ports 25565-25569, so you can create a server and start it straight away. Wings runs its own Docker daemon inside the container.

```sh
scripts/docker-test          # build the image, boot NixOS + systemd in a container
# open http://localhost:8080 and log in as admin / changeme123
scripts/docker-test shell    # root shell inside (try: systemctl status 'pterodactyl*')
scripts/docker-test logs     # follow the journal
scripts/docker-test stop     # remove the container (data volumes are kept)
scripts/docker-test purge    # remove the container and its volumes
```

`PORT=9000 scripts/docker-test` publishes the panel on a different port. Links the panel generates will still point at `APP_URL` (`http://localhost:8080`), which is set in `docker/configuration.nix`, and Wings only accepts browser connections from that origin. Wings itself is published on ports 8081 (API and console websocket) and 2022 (SFTP), and the allocations on 25565-25569 (TCP and UDP); those ports are fixed.

The container runs `--privileged` because systemd and the inner Docker daemon need it. The test image's admin password is stored world-readable in the Nix store, so use it for local testing only.

## Development

```sh
scripts/nix build .#pterodactyl-panel --print-out-paths
scripts/nix build .#pterodactyl-wings --print-out-paths
scripts/nix flake check      # evaluates everything and runs the VM test (fast with /dev/kvm)
scripts/nix fmt
```

Files written by Nix in the container (for example `flake.lock`) end up owned by root. Fix that with `docker run --rm -v "$PWD:/src" nixos/nix chown "$(id -u):$(id -g)" /src/flake.lock`.

The flake reads files from git, so run `git add` on new files before building.

### Updating the panel

1. Bump `version` in `pkgs/pterodactyl-panel/package.nix`.
2. Set the `src` `hash` and `vendorHash` to `lib.fakeHash`, build, and copy in the hashes Nix reports (two builds).
3. Run `scripts/nix flake check`.

### Updating Wings

The steps are the same as for the panel, in `pkgs/pterodactyl-wings/package.nix`: bump `version`, set `src.hash` and `vendorHash` to `lib.fakeHash`, build twice to get the real hashes, then run `scripts/nix flake check`. Check the Wings release notes for which panel versions it supports.
