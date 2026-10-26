# For testing only: registers this machine's Wings as a node in this
# machine's panel, with the UUID, token ID and token from the Wings
# configuration, so the two can talk to each other without manual setup.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  wings = config.services.pterodactyl-wings;
  panel = config.services.pterodactyl-panel;
  cfg = config.pterodactyl-test.localNode;

  php = pkgs.writeText "pterodactyl-local-node.php" ''
    use Pterodactyl\Models\Allocation;
    use Pterodactyl\Models\Location;
    use Pterodactyl\Models\Node;

    $token = rtrim(file_get_contents(getenv('CREDENTIALS_DIRECTORY') . '/token'), "\n");
    $node = Node::query()->where('uuid', ${builtins.toJSON wings.settings.uuid})->first();
    if (!$node) {
        $location = Location::query()->firstOrCreate(['short' => 'local'], ['long' => 'This machine']);
        $node = app(Pterodactyl\Services\Nodes\NodeCreationService::class)->handle([
            'name' => 'local',
            'location_id' => $location->id,
            'fqdn' => ${builtins.toJSON cfg.fqdn},
            'scheme' => 'http',
            'behind_proxy' => false,
            'public' => true,
            'memory' => 8192,
            'memory_overallocate' => -1,
            'disk' => 20480,
            'disk_overallocate' => -1,
            'upload_size' => 100,
            'daemonListen' => ${toString wings.settings.api.port},
            'daemonSFTP' => ${toString wings.settings.system.sftp.bind_port},
            'daemonBase' => ${builtins.toJSON "${wings.settings.system.root_directory}/volumes"},
        ]);
        echo "Created node {$node->id}\n";
    }
    $node->forceFill([
        'uuid' => ${builtins.toJSON wings.settings.uuid},
        'daemon_token_id' => ${builtins.toJSON wings.settings.token_id},
        'daemon_token' => app(Illuminate\Contracts\Encryption\Encrypter::class)->encrypt($token),
    ])->save();
    foreach (${builtins.toJSON cfg.allocations} as $port) {
        Allocation::query()->firstOrCreate(['node_id' => $node->id, 'ip' => '0.0.0.0', 'port' => $port]);
    }
  '';
in
{
  options.pterodactyl-test.localNode = {
    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Address browsers use to reach Wings.";
    };
    allocations = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Ports to create allocations for, on 0.0.0.0.";
    };
  };

  config.systemd.services.pterodactyl-local-node = {
    description = "Register the local Wings node in the panel";
    requiredBy = [ "pterodactyl-wings.service" ];
    before = [ "pterodactyl-wings.service" ];
    requires = [ "pterodactyl-panel-setup.service" ];
    after = [ "pterodactyl-panel-setup.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = panel.user;
      LoadCredential = "token:${wings.tokenFile}";
    };
    script = ''
      pterodactyl-artisan tinker --execute="$(< ${php})"
    '';
  };
}
