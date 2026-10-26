# End-to-end test in a QEMU VM: boots the module with its defaults and checks
# that the panel serves its login page and that the admin can log in through
# the API.
{ self, pkgs }:

pkgs.testers.runNixOSTest {
  name = "pterodactyl-panel";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 2048;
      services.pterodactyl-panel = {
        enable = true;
        hostName = "localhost";
        settings = {
          RECAPTCHA_ENABLED = false;
          # Exercises escaping in the generated .env.
          APP_NAME = ''Ptero "test" $HOME \ panel'';
          MAIL_PASSWORD._secret = "/etc/pterodactyl-test/mail-password";
        };
        initialAdmin = {
          email = "admin@example.com";
          username = "admin";
          passwordFile = "/etc/pterodactyl-test/admin-password";
        };
      };
      # Secret options reject store paths, so the test secrets are files in
      # /etc. Their text is still copied from the store, which is fine here.
      environment.etc = {
        "pterodactyl-test/mail-password" = {
          text = "s3cr3t$with\"quotes";
          mode = "0400";
          user = "pterodactyl";
        };
        "pterodactyl-test/admin-password" = {
          text = "changeme123";
          mode = "0400";
        };
      };
      environment.systemPackages = [ pkgs.jq ];
    };

  testScript = ''
    import json
    import urllib.parse

    machine.wait_for_unit("pterodactyl-panel-setup.service")
    machine.wait_for_unit("phpfpm-pterodactyl-panel.service")
    machine.wait_for_unit("pterodactyl-panel-queue.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(80)

    with subtest("login page is served"):
        page = machine.succeed("curl -sf http://localhost/auth/login")
        assert 'id="app"' in page, page
        # The compiled frontend from the release tarball is served.
        machine.succeed("curl -sf -o /dev/null http://localhost/assets/manifest.json")

    with subtest(".env values are escaped and secrets resolved"):
        out = machine.succeed(
            "pterodactyl-artisan tinker --execute='echo json_encode([config(\"app.name\"), config(\"mail.mailers.smtp.password\")]);'"
        )
        name, password = json.loads(out.strip().splitlines()[-1])
        assert name == 'Ptero "test" $HOME \\ panel', name
        assert password == 's3cr3t$with"quotes', password
        machine.succeed("stat -c %a /var/lib/pterodactyl-panel/.env | grep -qx 600")

    with subtest("initial admin exists and can log in"):
        machine.succeed(
            "pterodactyl-artisan tinker --execute='echo Pterodactyl\\Models\\User::where(\"username\", \"admin\")->where(\"root_admin\", true)->count();' | tail -n1 | grep -qx 1"
        )
        machine.succeed("curl -sf -c /tmp/jar http://localhost/sanctum/csrf-cookie")
        raw = machine.succeed("awk '$6 == \"XSRF-TOKEN\" {print $7}' /tmp/jar").strip()
        token = urllib.parse.unquote(raw)
        machine.succeed(
            f"curl -sf -c /tmp/jar -b /tmp/jar -H 'X-XSRF-TOKEN: {token}' -H 'Accept: application/json'"
            " -H 'Content-Type: application/json' -d '{\"user\":\"admin\",\"password\":\"changeme123\"}'"
            " http://localhost/auth/login | jq -e '.data.complete == true'"
        )

    with subtest("scheduler and redis-backed queue work"):
        machine.succeed("systemctl start pterodactyl-panel-scheduler.service")
        machine.succeed("pterodactyl-artisan queue:monitor redis:high")

    with subtest("setup is idempotent and keeps state"):
        # Restarting setup must not flush the Redis cache (which shares its
        # database with the queue and sessions) or re-seed edited stock eggs.
        machine.succeed(
            "pterodactyl-artisan tinker --execute='cache()->put(\"nixos-test\", \"kept\", 3600); Pterodactyl\\Models\\Egg::query()->orderBy(\"id\")->first()->update([\"startup\" => \"nixos-test\"]);'"
        )
        machine.succeed("systemctl restart pterodactyl-panel-setup.service")
        machine.succeed("curl -sf http://localhost/auth/login")
        out = machine.succeed(
            "pterodactyl-artisan tinker --execute='echo json_encode([cache()->get(\"nixos-test\"), Pterodactyl\\Models\\Egg::query()->orderBy(\"id\")->first()->startup]);'"
        )
        assert json.loads(out.strip().splitlines()[-1]) == ["kept", "nixos-test"], out

    with subtest("initial admin is not re-created after losing the marker"):
        machine.succeed("rm /var/lib/pterodactyl-panel/.initial-admin-created")
        machine.succeed("systemctl restart pterodactyl-panel-setup.service")
        machine.succeed("test -e /var/lib/pterodactyl-panel/.initial-admin-created")
  '';
}
