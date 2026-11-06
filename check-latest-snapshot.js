// Check the latest snapshot data including terminal_algo_trading_enabled
require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

(async () => {
  try {
    const result = await pool.query(`
      SELECT
        login,
        terminal_algo_trading_enabled,
        received_at,
        ea_version
      FROM snapshots
      WHERE login IN (1394493, 26446415, 34158893)
      ORDER BY received_at DESC
      LIMIT 10
    `);

    console.log('\n=== Latest Snapshots ===\n');
    result.rows.forEach(row => {
      console.log(`Login: ${row.login}`);
      console.log(`  terminal_algo_trading_enabled: ${row.terminal_algo_trading_enabled}`);
      console.log(`  received_at: ${new Date(row.received_at * 1000).toISOString()}`);
      console.log(`  EA version: ${row.ea_version || 'unknown'}`);
      console.log('');
    });

    await pool.end();
    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
})();
