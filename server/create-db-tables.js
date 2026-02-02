// Script to create database and tables if they don't exist
const { Client } = require('pg');
const url = require('url');

async function setupDatabase() {
  let dbUrl = process.env.DATABASE_URL;
  
  // Check if DATABASE_URL is a template variable (Railway)
  if (!dbUrl || dbUrl.includes('{{') || dbUrl.includes('${{')) {
    console.error('ERROR: DATABASE_URL appears to be a template variable or is not set!');
    console.error('DATABASE_URL value:', dbUrl || '(not set)');
    console.error('');
    console.error('In Railway:');
    console.error('1. Make sure PostgreSQL service is added to your project');
    console.error('2. Railway should automatically provide DATABASE_URL');
    console.error('3. Check service variables in Railway dashboard');
    console.error('4. The variable should be automatically linked, not a template');
    process.exit(1);
  }
  
  if (!dbUrl.includes('postgresql://')) {
    console.log('DATABASE_URL is not a PostgreSQL connection string, skipping database setup');
    return;
  }

  try {
    const parsed = url.parse(dbUrl);
    const dbName = parsed.pathname?.slice(1)?.split('?')[0];
    
    if (!dbName) {
      console.log('ERROR: Could not extract database name from DATABASE_URL');
      process.exit(1);
    }

    console.log(`Setting up database: ${dbName}`);

    // Connect to postgres database to create our database
    const adminUrl = dbUrl.replace('/' + dbName, '/postgres');
    const adminClient = new Client({ connectionString: adminUrl });
    
    await adminClient.connect();
    console.log('Connected to PostgreSQL server');

    // Check if database exists
    const dbCheck = await adminClient.query(
      'SELECT 1 FROM pg_database WHERE datname = $1',
      [dbName]
    );

    if (dbCheck.rows.length === 0) {
      console.log(`Database "${dbName}" does not exist, creating...`);
      await adminClient.query(`CREATE DATABASE "${dbName.replace(/"/g, '""')}"`);
      console.log(`✓ Database "${dbName}" created successfully`);
    } else {
      console.log(`✓ Database "${dbName}" already exists`);
    }

    await adminClient.end();

    // Now connect to our database and create tables using Prisma
    console.log('Creating tables using Prisma...');
    const { execSync } = require('child_process');
    
    try {
      execSync('npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate', {
        stdio: 'inherit',
        cwd: '/app/server',
        env: { ...process.env, DATABASE_URL: dbUrl }
      });
      console.log('✓ Tables created successfully');
    } catch (error) {
      console.error('ERROR: Failed to create tables:', error.message);
      process.exit(1);
    }

  } catch (error) {
    console.error('ERROR setting up database:', error.message);
    // Don't exit - let Prisma handle it
    console.log('Continuing - Prisma will attempt to create tables...');
  }
}

setupDatabase();
