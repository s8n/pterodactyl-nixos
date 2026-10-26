# pterodactyl-nixos

A Nix package and a NixOS module for [Pterodactyl Panel](https://pterodactyl.io) 1.15.2, the web panel only (not Wings).

- `pkgs/pterodactyl-panel/package.nix`: builds the panel from the upstream release tarball (frontend already compiled) with `buildComposerProject2` on PHP 8.3.
- `nixos/module.nix`: `services.pterodactyl-panel`. Sets up PHP-FPM, nginx, the queue worker, the scheduler timer, database migrations, and by default a local MariaDB and Redis.
- `docker/`: a NixOS system that boots with systemd inside a Docker container, for trying the module out.
- `tests/vm.nix`: a NixOS VM test (`nix flake check`).

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

### Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `hostName` | none | nginx virtual host and default `APP_URL`. |
| `settings` | see below | Written to `.env`. Any variable from upstream's `.env.example` / `config/*.php`. `{ _secret = path; }` reads a value from a file at service start. |
| `appKeyFile`, `hashidsSaltFile` | `null` | If null, they are generated on first start into `${dataDir}/secrets/`. **Back up `app-key`**: without it, node tokens, database host passwords and 2FA secrets can't be decrypted. |
| `database.createLocally` | `true` | Local MariaDB over the Unix socket with socket auth, so no password is needed. Set to `false` and use `database.{host,port,name,user,passwordFile}` for an external database. |
| `redis.createLocally` | `true` | Dedicated Redis on a Unix socket, used for cache, sessions and the queue. |
| `initialAdmin` | `null` | Created once, on first start. |
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

### Services

| Unit | What it does |
|---|---|
| `pterodactyl-panel-setup.service` | Oneshot. Generates missing secrets, writes `.env`, clears caches, runs `migrate --seed --force`, creates the initial admin. Runs again when the package or settings change, so upgrades apply migrations automatically. |
| `phpfpm-pterodactyl-panel.service` | PHP-FPM pool. |
| `pterodactyl-panel-queue.service` | `artisan queue:work` (upstream calls this `pteroq`). |
| `pterodactyl-panel-scheduler.timer` | `artisan schedule:run` every minute. |

## Trying it in Docker

You don't need Nix on the host: `scripts/nix` runs Nix inside the `nixos/nix` image and keeps its store in the `pterodactyl-nix-store` Docker volume.

```sh
scripts/docker-test          # build the image, boot NixOS + systemd in a container
# open http://localhost:8080 and log in as admin / changeme123
scripts/docker-test shell    # root shell inside (try: systemctl status 'pterodactyl*')
scripts/docker-test logs     # follow the journal
scripts/docker-test stop     # remove the container (data volumes are kept)
scripts/docker-test purge    # remove the container and its volumes
```

`PORT=9000 scripts/docker-test` publishes on a different port. Links the panel generates will still point at `APP_URL` (`http://localhost:8080`), which is set in `docker/configuration.nix`.

The container runs `--privileged` because systemd needs it. The test image's admin password is stored world-readable in the Nix store, so use it for local testing only.

## Development

```sh
scripts/nix build .#pterodactyl-panel --print-out-paths
scripts/nix flake check      # evaluates everything and runs the VM test (fast with /dev/kvm)
scripts/nix fmt
```

Files written by Nix in the container (for example `flake.lock`) end up owned by root. Fix that with `docker run --rm -v "$PWD:/src" nixos/nix chown "$(id -u):$(id -g)" /src/flake.lock`.

The flake reads files from git, so run `git add` on new files before building.

### Updating the panel

1. Bump `version` in `pkgs/pterodactyl-panel/package.nix`.
2. Set the `src` `hash` and `vendorHash` to `lib.fakeHash`, build, and copy in the hashes Nix reports (two builds).
3. Run `scripts/nix flake check`.
