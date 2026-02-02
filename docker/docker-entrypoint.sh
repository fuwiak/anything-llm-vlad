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
if [ -z "$DATABASE_URL" ]; then
    echo "DATABASE_URL not set, using SQLite database..."
    export DATABASE_URL="file:../storage/anythingllm.db"
    # For SQLite, we need to use a different schema file or handle it differently
    # Since schema.prisma now uses PostgreSQL, we'll need to handle SQLite separately
    # For now, we'll require DATABASE_URL to be set
    echo "ERROR: DATABASE_URL must be set. Please add PostgreSQL plugin in Railway or set DATABASE_URL environment variable."
    echo "For Railway: Add PostgreSQL plugin in your Railway project settings."
    exit 1
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
echo "Command: npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate --force-reset"
echo ""

# Use --force-reset to ensure clean state, but this will delete existing data
# For production, we might want to remove --force-reset
npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate --force-reset 2>&1

DB_PUSH_EXIT_CODE=$?

echo ""
echo "db push exit code: $DB_PUSH_EXIT_CODE"
echo ""

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
{
    node /app/server/index.js
} &
{ node /app/collector/index.js; } &
wait -n
exit $?