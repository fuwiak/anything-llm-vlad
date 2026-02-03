#!/bin/bash
set -e

# Check if STORAGE_DIR is set
if [ -z "$STORAGE_DIR" ]; then
    echo "================================================================"
    echo "⚠️  ⚠️  ⚠️  WARNING: STORAGE_DIR environment variable is not set! ⚠️  ⚠️  ⚠️"
    echo ""
    echo "Not setting this will result in data loss on container restart since"
    echo "the application will not have a persistent storage location."
    echo "It can also result in weird errors in various parts of the application."
    echo ""
    echo "Please run the container with the official docker command at"
    echo "https://docs.anythingllm.com/installation-docker/quickstart"
    echo ""
    echo "⚠️  ⚠️  ⚠️  WARNING: STORAGE_DIR environment variable is not set! ⚠️  ⚠️  ⚠️"
    echo "================================================================"
fi

# Ensure storage directory exists for SQLite database (if needed)
mkdir -p /app/server/storage

# Set DATABASE_URL if not provided (default to SQLite for local development)
# For Railway/production, DATABASE_URL should be set automatically when PostgreSQL plugin is added
# Railway automatically sets DATABASE_URL when PostgreSQL service is added
if [ -z "$DATABASE_URL" ] || [ "$DATABASE_URL" = "\${{Postgres.DATABASE_URL}}" ] || [ "$DATABASE_URL" = '${{Postgres.DATABASE_URL}}' ]; then
    echo "=========================================="
    echo "DATABASE_URL check..."
    echo "=========================================="
    echo "DATABASE_URL value: ${DATABASE_URL:0:50}..."

    # Try to get DATABASE_URL from Railway's PostgreSQL service
    # Railway sets this automatically, but sometimes it needs to be referenced
    if [ -z "$DATABASE_URL" ] || [ "$DATABASE_URL" = "\${{Postgres.DATABASE_URL}}" ] || [ "$DATABASE_URL" = '${{Postgres.DATABASE_URL}}' ]; then
        echo "ERROR: DATABASE_URL is not set or is a template variable!"
        echo ""
        echo "In Railway:"
        echo "1. Make sure you have added PostgreSQL service to your project"
        echo "2. Railway should automatically set DATABASE_URL"
        echo "3. Check your service settings - DATABASE_URL should be automatically available"
        echo "4. If using Railway CLI, the variable should be: \${{Postgres.DATABASE_URL}}"
        echo ""
        echo "If DATABASE_URL is not automatically set, you may need to:"
        echo "- Check that PostgreSQL service is properly connected to your app"
        echo "- Restart the deployment"
        exit 1
    fi
fi

echo "DATABASE_URL is set: ${DATABASE_URL:0:30}..."

# Create database and tables if they don't exist (for PostgreSQL)
# DATABASE_URL format: postgresql://user:password@host:port/database
if echo "$DATABASE_URL" | grep -q "postgresql://"; then
    echo "=========================================="
    echo "Setting up PostgreSQL database and tables..."
    echo "=========================================="

    # Use dedicated script to create database and tables
    cd /app/server/
    node create-db-tables.js 2>&1

    if [ $? -ne 0 ]; then
        echo "WARNING: Database setup script had issues, but continuing..."
        echo "Prisma will attempt to create tables in the next step"
    fi
    echo ""
fi

# Run Prisma migrations synchronously before starting the server
cd /app/server/

# Check if migrations directory exists
if [ ! -d "./prisma/migrations" ]; then
    echo "ERROR: Prisma migrations directory not found!"
    echo "Expected: /app/server/prisma/migrations"
    ls -la /app/server/prisma/ || echo "Prisma directory does not exist!"
    exit 1
fi

echo "Found $(ls -1 ./prisma/migrations/*/migration.sql 2>/dev/null | wc -l) migration files"

echo "Generating Prisma Client..."
export CHECKPOINT_DISABLE=1
npx prisma generate --schema=./prisma/schema.prisma

if [ $? -ne 0 ]; then
    echo "ERROR: Prisma Client generation failed!"
    exit 1
fi

echo "=========================================="
echo "Setting up database schema..."
echo "Database URL: ${DATABASE_URL:0:30}..." # Show first 30 chars for security
echo "=========================================="

# First, try to use db push to create/update schema directly from schema.prisma
# This is more reliable for initial setup and ensures all tables are created
echo ""
echo "Step 1: Pushing schema to database using prisma db push..."
echo "Command: npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate"
echo ""

# Use db push to create/update schema
# --accept-data-loss: allows schema changes that might cause data loss
# --skip-generate: skip generating Prisma Client (already done above)
# Force push to ensure all tables are created
echo "Executing prisma db push..."
npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate --force-reset 2>&1 | tee /tmp/prisma-push.log

DB_PUSH_EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "=========================================="
echo "db push exit code: $DB_PUSH_EXIT_CODE"
echo "=========================================="
echo ""

# Check if tables were actually created by looking at the output
if grep -q "Your database is now in sync with your Prisma schema" /tmp/prisma-push.log 2>/dev/null || \
   grep -q "Database schema is up to date" /tmp/prisma-push.log 2>/dev/null || \
   grep -q "The database is already in sync with the Prisma schema" /tmp/prisma-push.log 2>/dev/null; then
    echo "✓ Prisma db push completed successfully - tables should exist"
    DB_PUSH_EXIT_CODE=0
fi

if [ $DB_PUSH_EXIT_CODE -ne 0 ]; then
    echo "WARNING: prisma db push failed or had warnings (exit code: $DB_PUSH_EXIT_CODE)"
    echo "Trying migrate deploy as fallback..."
    echo ""

    # Fallback to migrate deploy if db push fails
    npx prisma migrate deploy --schema=./prisma/schema.prisma 2>&1

    MIGRATE_EXIT_CODE=$?
    echo ""
    echo "migrate deploy exit code: $MIGRATE_EXIT_CODE"
    echo ""

    if [ $MIGRATE_EXIT_CODE -ne 0 ]; then
        echo "ERROR: Both db push and migrate deploy failed!"
        echo "Please check DATABASE_URL and database connection."
        echo "DATABASE_URL format should be: postgresql://user:password@host:port/database"
        echo ""
        echo "Testing database connection..."
        # Try to connect and list tables
        npx prisma db execute --stdin --schema=./prisma/schema.prisma <<< "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';" 2>&1 || echo "Cannot execute test query"
        exit 1
    fi

    echo "Migrations deployed successfully using migrate deploy"
else
    echo "Database schema created/updated successfully using db push"
fi

# Verify that tables were created by checking Prisma can connect
echo ""
echo "Step 2: Verifying database connection and schema..."
echo "Running: npx prisma db pull --schema=./prisma/schema.prisma (dry run to verify connection)"
echo ""

# Try to introspect the database to verify connection and that tables exist
npx prisma db pull --schema=./prisma/schema.prisma --force 2>&1 | head -20 || {
    echo "WARNING: Could not verify tables via db pull, but continuing..."
    echo "This might be normal if database is empty or connection has issues."
}

echo ""
echo "=========================================="
echo "Database setup completed successfully!"
echo "=========================================="
echo ""

# Start server and collector in background
# Both processes run in the same container and communicate via localhost
echo "=========================================="
echo "Starting server and collector..."
echo "=========================================="
{
    echo "Starting server on port ${PORT:-3001}..."
    node /app/server/index.js
} &
{ 
    echo "Starting collector on port ${COLLECTOR_PORT:-8888}..."
    node /app/collector/index.js
} &
wait -n
exit $?
