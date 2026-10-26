<?php

// Creates the module's initial administrator. Run from the panel's directory:
//
//   php initial-admin.php <email> <username> <first name> <last name>
//
// The password is read from $CREDENTIALS_DIRECTORY/initial-admin-password
// rather than taken as an argument, which would expose it in the process list.
// If a user with the same email or username already exists, nothing is done.

[, $email, $username, $nameFirst, $nameLast] = $argv;

require getcwd() . '/vendor/autoload.php';
$app = require getcwd() . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$exists = Pterodactyl\Models\User::query()
    ->where('email', $email)
    ->orWhere('username', mb_strtolower($username))
    ->exists();
if ($exists) {
    echo "A user with email {$email} or username {$username} already exists; not creating the initial administrator.\n";
    exit(0);
}

$passwordFile = getenv('CREDENTIALS_DIRECTORY') . '/initial-admin-password';
$password = @file_get_contents($passwordFile);
if ($password === false) {
    fwrite(STDERR, "Cannot read {$passwordFile}\n");
    exit(1);
}
// Like `$(< file)` in the shell: ignore trailing newlines.
$password = rtrim($password, "\n");
if ($password === '') {
    fwrite(STDERR, "The initial administrator's password file is empty\n");
    exit(1);
}

$app->make(Pterodactyl\Services\Users\UserCreationService::class)->handle([
    'email' => $email,
    'username' => $username,
    'name_first' => $nameFirst,
    'name_last' => $nameLast,
    'password' => $password,
    'root_admin' => true,
]);

echo "Created initial administrator {$username}\n";
