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

echo "Setting up database schema..."
echo "Database URL: ${DATABASE_URL:0:30}..." # Show first 20 chars for security

# First, try to use db push to create/update schema directly from schema.prisma
# This is more reliable for initial setup and ensures all tables are created
echo "Executing: npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate"
npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate

DB_PUSH_EXIT_CODE=$?

if [ $DB_PUSH_EXIT_CODE -ne 0 ]; then
    echo "ERROR: prisma db push failed (exit code: $DB_PUSH_EXIT_CODE)"
    echo "Trying migrate deploy as fallback..."
    
    # Fallback to migrate deploy if db push fails
    npx prisma migrate deploy --schema=./prisma/schema.prisma
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Both db push and migrate deploy failed!"
        echo "Please check DATABASE_URL and database connection."
        echo "DATABASE_URL format should be: postgresql://user:password@host:port/database"
        exit 1
    fi
    
    echo "Migrations deployed successfully using migrate deploy"
else
    echo "Database schema created/updated successfully using db push"
    
    # After successful db push, mark migrations as applied
    # This prevents issues if migrate deploy is run later
    echo "Marking migrations as applied..."
    npx prisma migrate resolve --applied --schema=./prisma/schema.prisma "*" 2>/dev/null || true
fi

echo "Prisma migrations completed successfully. Starting server..."

# Start server and collector in background
{
  node /app/server/index.js
} &
{ node /app/collector/index.js; } &
wait -n
exit $?