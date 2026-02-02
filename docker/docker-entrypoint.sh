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
echo "Generating Prisma Client..."
export CHECKPOINT_DISABLE=1
npx prisma generate --schema=./prisma/schema.prisma

echo "Running Prisma migrations..."
echo "Database URL: ${DATABASE_URL:0:20}..." # Show first 20 chars for security
npx prisma migrate deploy --schema=./prisma/schema.prisma

if [ $? -ne 0 ]; then
    echo "ERROR: Prisma migrations failed!"
    exit 1
fi

echo "Prisma migrations completed successfully. Starting server..."

# Start server and collector in background
{
  node /app/server/index.js
} &
{ node /app/collector/index.js; } &
wait -n
exit $?