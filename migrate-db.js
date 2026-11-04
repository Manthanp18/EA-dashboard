// Manual database migration script
// Run this once to fix the schema on Render

const { Pool } = require('pg');

const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('❌ DATABASE_URL environment variable is required');
  console.log('Usage: DATABASE_URL="your-postgres-url" node migrate-db.js');
  process.exit(1);
}

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: { rejectUnauthorized: false }
});

async function migrate() {
  try {
    console.log('🔄 Starting database migration...\n');

    // Drop old columns from snapshots table
    console.log('Step 1: Dropping old columns from snapshots table...');
    await pool.query(`
      DO $$
      BEGIN
        -- Drop old column names
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='realized_bank') THEN
          ALTER TABLE snapshots DROP COLUMN realized_bank;
          RAISE NOTICE 'Dropped column: realized_bank';
        END IF;

        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='floating_pnl') THEN
          ALTER TABLE snapshots DROP COLUMN floating_pnl;
          RAISE NOTICE 'Dropped column: floating_pnl';
        END IF;

        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='net_pnl') THEN
          ALTER TABLE snapshots DROP COLUMN net_pnl;
          RAISE NOTICE 'Dropped column: net_pnl';
        END IF;
      END $$;
    `);
    console.log('✅ Old columns dropped\n');

    // Add new columns
    console.log('Step 2: Adding new cycle_* columns...');
    await pool.query(`
      DO $$
      BEGIN
        -- Add core cycle columns
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_net') THEN
          ALTER TABLE snapshots ADD COLUMN cycle_net REAL NOT NULL DEFAULT 0;
          RAISE NOTICE 'Added column: cycle_net';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_realized_bank') THEN
          ALTER TABLE snapshots ADD COLUMN cycle_realized_bank REAL NOT NULL DEFAULT 0;
          RAISE NOTICE 'Added column: cycle_realized_bank';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_floating') THEN
          ALTER TABLE snapshots ADD COLUMN cycle_floating REAL NOT NULL DEFAULT 0;
          RAISE NOTICE 'Added column: cycle_floating';
        END IF;
      END $$;
    `);
    console.log('✅ New columns added\n');

    // Verify schema
    console.log('Step 3: Verifying schema...');
    const result = await pool.query(`
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'snapshots'
      AND column_name IN ('realized_bank', 'floating_pnl', 'net_pnl', 'cycle_net', 'cycle_realized_bank', 'cycle_floating')
      ORDER BY column_name;
    `);

    console.log('\nCurrent snapshot columns:');
    result.rows.forEach(row => {
      console.log(`  - ${row.column_name}: ${row.data_type} (nullable: ${row.is_nullable})`);
    });

    console.log('\n✅ Migration completed successfully!');
    console.log('\nExpected result:');
    console.log('  - OLD columns (realized_bank, floating_pnl, net_pnl) should be GONE');
    console.log('  - NEW columns (cycle_net, cycle_realized_bank, cycle_floating) should exist');

    await pool.end();
    process.exit(0);
  } catch (err) {
    console.error('\n❌ Migration failed:', err.message);
    console.error(err);
    await pool.end();
    process.exit(1);
  }
}

migrate();
