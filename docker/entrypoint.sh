#!/bin/sh
set -eu

if [ -z "${APP_KEY:-}" ]; then
    echo "APP_KEY must be set before starting the application." >&2
    exit 1
fi

mkdir -p \
    storage/app/public \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/testing \
    storage/framework/views \
    storage/logs \
    bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache

db_wait_retries=${DB_WAIT_RETRIES:-30}
db_wait_interval=${DB_WAIT_INTERVAL:-2}

case "$db_wait_retries" in
    ''|*[!0-9]*|0)
        echo "DB_WAIT_RETRIES must be a positive integer." >&2
        exit 1
        ;;
esac
case "$db_wait_interval" in
    ''|*[!0-9]*)
        echo "DB_WAIT_INTERVAL must be a non-negative integer." >&2
        exit 1
        ;;
esac

attempt=1
until php -r '
    $host = getenv("DB_HOST") ?: "database";
    $port = getenv("DB_PORT") ?: "3306";
    $database = getenv("DB_DATABASE") ?: "";
    $username = getenv("DB_USERNAME") ?: "";
    $password = getenv("DB_PASSWORD") ?: "";

    try {
        new PDO(
            "mysql:host={$host};port={$port};dbname={$database}",
            $username,
            $password,
            [PDO::ATTR_TIMEOUT => 3]
        );
    } catch (Throwable $exception) {
        fwrite(STDERR, $exception->getMessage() . PHP_EOL);
        exit(1);
    }
'; do
    if [ "$attempt" -ge "$db_wait_retries" ]; then
        echo "MySQL was not ready after ${db_wait_retries} attempts." >&2
        exit 1
    fi

    echo "Waiting for MySQL (attempt ${attempt}/${db_wait_retries})..."
    sleep "$db_wait_interval"
    attempt=$((attempt + 1))
done

if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    php artisan migrate --force
fi

if [ "${RUN_SEEDERS:-false}" = "true" ]; then
    php -r '
        require "vendor/autoload.php";
        $app = require "bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

        if (
            Illuminate\Support\Facades\Schema::hasTable("users")
            && Illuminate\Support\Facades\DB::table("users")->doesntExist()
        ) {
            $exitCode = Illuminate\Support\Facades\Artisan::call(
                "db:seed",
                ["--force" => true]
            );
            echo Illuminate\Support\Facades\Artisan::output();
            exit($exitCode);
        }

        echo "Skipping seeders: the users table is not empty or does not exist." . PHP_EOL;
    '
fi

if [ ! -L public/storage ]; then
    php artisan storage:link
fi

php artisan config:cache
php artisan view:cache

exec "$@"
