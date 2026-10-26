{
  lib,
  fetchzip,
  php83,
  # Mutable state lives outside the store. The NixOS module overrides these to
  # match `services.pterodactyl-panel.dataDir`.
  dataDir ? "/var/lib/pterodactyl-panel",
}:

let
  # Upstream builds and tests against PHP 8.3. The default extension set
  # already covers everything the panel needs (bcmath, gd, mbstring, pdo_mysql,
  # posix, zip, ...).
  php = php83.buildEnv {
    extraConfig = ''
      memory_limit = 256M
    '';
  };
in
php.buildComposerProject2 (finalAttrs: {
  pname = "pterodactyl-panel";
  version = "1.15.2";

  # The release tarball ships the compiled frontend (public/assets), so no
  # Node.js build is needed here. It has no top-level directory.
  src = fetchzip {
    url = "https://github.com/pterodactyl/panel/releases/download/v${finalAttrs.version}/panel.tar.gz";
    hash = "sha256-A+M7IJf0GP7E6PiTRMErPTBKawkh2HRJw9nqCGxjcEY=";
    stripRoot = false;
  };

  vendorHash = "sha256-cTsJsPopq94VojzzOxC7YEOOXRNf61i1xD20HjMTHOA=";

  inherit php;

  postInstall = ''
    app="$out/share/php/${finalAttrs.pname}"

    # Frontend sources and dev tooling aren't needed at runtime.
    rm -rf "$app"/{resources/scripts,babel.config.js,jest.config.js,package.json,yarn.lock} \
      "$app"/{postcss.config.js,tailwind.config.js,tsconfig.json,webpack.config.js,phpstan.neon} \
      "$app"/{Dockerfile,docker-compose.example.yml,.eslintrc.js,.eslintignore,.prettierrc.json,.editorconfig}

    # Point everything Laravel writes to at the state directory.
    rm -rf "$app/storage" "$app/bootstrap/cache"
    ln -s ${dataDir}/storage "$app/storage"
    ln -s ${dataDir}/bootstrap-cache "$app/bootstrap/cache"
    ln -s ${dataDir}/.env "$app/.env"
  '';

  passthru = {
    phpPackage = php;
  };

  meta = {
    description = "Free, open-source game server management panel built with PHP, React, and Go";
    homepage = "https://pterodactyl.io";
    changelog = "https://github.com/pterodactyl/panel/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
