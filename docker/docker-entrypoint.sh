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

# Ensure storage directory exists for SQLite database
mkdir -p /app/server/storage

# Run Prisma migrations synchronously before starting the server
cd /app/server/
echo "Generating Prisma Client..."
export CHECKPOINT_DISABLE=1
npx prisma generate --schema=./prisma/schema.prisma

echo "Running Prisma migrations..."
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