const { Pool } = require('pg');
const crypto = require('crypto');

// PostgreSQL connection
const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('❌ ERROR: DATABASE_URL environment variable is required');
  process.exit(1);
}

console.log('=== DATABASE INITIALIZATION ===');
console.log('Connecting to PostgreSQL...');

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Test connection
pool.query('SELECT NOW()')
  .then(() => {
    console.log('✅ PostgreSQL connected successfully');
  })
  .catch(err => {
    console.error('❌ PostgreSQL connection failed:', err.message);
    process.exit(1);
  });

// Initialize schema
async function initializeSchema() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS accounts (
        login BIGINT PRIMARY KEY,
        label TEXT NOT NULL,
        created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
        last_seen_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT
      );

      CREATE TABLE IF NOT EXISTS snapshots (
        id SERIAL PRIMARY KEY,
        login BIGINT NOT NULL,

        -- Snapshot metadata
        schema_version INTEGER NOT NULL DEFAULT 1,
        snapshot_id TEXT,
        sampled_at_utc TEXT,
        source_mode TEXT,

        -- Account data
        account_name TEXT,
        server TEXT,
        currency TEXT NOT NULL DEFAULT 'USD',
        balance REAL NOT NULL,
        equity REAL NOT NULL,

        -- EA data
        ea_name TEXT,
        ea_version TEXT,
        ea_instance_id TEXT,
        ea_symbol TEXT,
        ea_magic TEXT,
        ea_status TEXT,

        -- Cycle data
        cycle_id TEXT,
        cycle_active BOOLEAN,
        cycle_net REAL NOT NULL,
        cycle_realized_bank REAL NOT NULL,
        cycle_floating REAL NOT NULL,
        cycle_active_target REAL,
        cycle_profit_basis TEXT,
        cycle_open_positions INTEGER,
        cycle_pending_orders INTEGER,
        cycle_accounting_confirmed BOOLEAN,

        received_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
        FOREIGN KEY (login) REFERENCES accounts(login)
      );

      CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
        expires_at BIGINT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_snapshots_login ON snapshots(login);
      CREATE INDEX IF NOT EXISTS idx_snapshots_received_at ON snapshots(received_at);
      CREATE INDEX IF NOT EXISTS idx_snapshots_login_received ON snapshots(login, received_at DESC);
      CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
    `);

    console.log('✅ Database schema initialized');
  } catch (err) {
    console.error('❌ Schema initialization error:', err.message);
    throw err;
  }
}

console.log('===============================');

// Initialize schema on startup
initializeSchema().catch(err => {
  console.error('Fatal error during schema initialization:', err);
  process.exit(1);
});

// Auto-create or update account when EA sends data
async function upsertAccount(login, label) {
  const now = Math.floor(Date.now() / 1000);
  const result = await pool.query(
    `INSERT INTO accounts (login, label, created_at, last_seen_at)
     VALUES ($1, $2, $3, $3)
     ON CONFLICT (login)
     DO UPDATE SET label = $2, last_seen_at = $3
     RETURNING *`,
    [login, label || `Account ${login}`, now]
  );
  return result.rows[0];
}

// Add a snapshot (with rate limiting - max once per 15 seconds per account)
async function addSnapshot(login, data) {
  const now = Math.floor(Date.now() / 1000);

  // Check if we have a recent snapshot (within last 15 seconds)
  const lastSnapshot = await pool.query(
    'SELECT received_at FROM snapshots WHERE login = $1 ORDER BY received_at DESC LIMIT 1',
    [login]
  );

  if (lastSnapshot.rows.length > 0 && (now - lastSnapshot.rows[0].received_at) < 15) {
    return null; // Skip this snapshot
  }

  const result = await pool.query(
    `INSERT INTO snapshots (
      login, schema_version, snapshot_id, sampled_at_utc, source_mode,
      account_name, server, currency, balance, equity,
      ea_name, ea_version, ea_instance_id, ea_symbol, ea_magic, ea_status,
      cycle_id, cycle_active, cycle_net, cycle_realized_bank, cycle_floating,
      cycle_active_target, cycle_profit_basis, cycle_open_positions,
      cycle_pending_orders, cycle_accounting_confirmed, received_at
    ) VALUES (
      $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15,
      $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27
    ) RETURNING *`,
    [
      login,
      data.schema_version || 1,
      data.snapshot_id || null,
      data.sampled_at_utc || null,
      data.source_mode || null,
      data.account?.name || null,
      data.account?.server || null,
      data.account?.currency || 'USD',
      data.account?.balance || 0,
      data.account?.equity || 0,
      data.ea?.name || null,
      data.ea?.version || null,
      data.ea?.instance_id || null,
      data.ea?.symbol || null,
      data.ea?.magic || null,
      data.ea?.status || null,
      data.cycle?.id || null,
      data.cycle?.active || null,
      data.cycle?.net || 0,
      data.cycle?.realized_bank || 0,
      data.cycle?.floating || 0,
      data.cycle?.active_target || null,
      data.cycle?.profit_basis || null,
      data.cycle?.open_positions || null,
      data.cycle?.pending_orders || null,
      data.cycle?.accounting_confirmed || null,
      now
    ]
  );

  return result.rows[0];
}

// Get latest snapshot for an account
async function getLatestSnapshot(login) {
  const result = await pool.query(
    `SELECT * FROM snapshots
     WHERE login = $1
     ORDER BY received_at DESC
     LIMIT 1`,
    [login]
  );
  return result.rows[0];
}

// Get historical snapshots
async function getHistory(login, hours = 24) {
  const sinceTimestamp = Math.floor(Date.now() / 1000) - (hours * 3600);
  const result = await pool.query(
    `SELECT * FROM snapshots
     WHERE login = $1 AND received_at >= $2
     ORDER BY received_at ASC`,
    [login, sinceTimestamp]
  );
  return result.rows;
}

// Get all accounts with their latest snapshots
async function getAllAccounts() {
  const result = await pool.query(`
    SELECT
      a.login,
      a.label,
      a.created_at,
      a.last_seen_at,
      s.balance,
      s.equity,
      s.cycle_net,
      s.cycle_realized_bank as realized_bank,
      s.cycle_floating as floating_pnl,
      s.currency,
      s.server,
      s.account_name,
      s.source_mode,
      s.ea_name,
      s.ea_version,
      s.ea_symbol,
      s.ea_magic,
      s.ea_status,
      s.cycle_id,
      s.cycle_active,
      s.cycle_active_target,
      s.cycle_profit_basis,
      s.cycle_open_positions,
      s.cycle_pending_orders,
      s.cycle_accounting_confirmed,
      s.received_at
    FROM accounts a
    LEFT JOIN LATERAL (
      SELECT *
      FROM snapshots
      WHERE snapshots.login = a.login
      ORDER BY received_at DESC
      LIMIT 1
    ) s ON true
    ORDER BY a.last_seen_at DESC
  `);

  const accounts = result.rows;
  console.log(`📊 getAllAccounts() returned ${accounts.length} account(s)`);
  if (accounts.length > 0) {
    accounts.forEach(acc => {
      console.log(`   - Login: ${acc.login}, Label: "${acc.label}", EA: ${acc.ea_name || 'N/A'}`);
    });
  }
  return accounts;
}

// Get account info by login
async function getAccountInfo(login) {
  const result = await pool.query(
    'SELECT login, label, created_at FROM accounts WHERE login = $1',
    [login]
  );
  return result.rows[0];
}

// Delete account and its snapshots
async function deleteAccount(login) {
  await pool.query('DELETE FROM snapshots WHERE login = $1', [login]);
  const result = await pool.query('DELETE FROM accounts WHERE login = $1', [login]);
  return { changes: result.rowCount };
}

// Session management
async function createSession(token) {
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + (30 * 24 * 3600); // 30 days
  const result = await pool.query(
    'INSERT INTO sessions (token, created_at, expires_at) VALUES ($1, $2, $3) RETURNING *',
    [token, now, expiresAt]
  );
  return result.rows[0];
}

async function verifySession(token) {
  const now = Math.floor(Date.now() / 1000);
  const result = await pool.query(
    'SELECT * FROM sessions WHERE token = $1 AND expires_at > $2',
    [token, now]
  );
  return result.rows.length > 0;
}

async function deleteSession(token) {
  const result = await pool.query('DELETE FROM sessions WHERE token = $1', [token]);
  return { changes: result.rowCount };
}

async function pruneExpiredSessions() {
  const now = Math.floor(Date.now() / 1000);
  const result = await pool.query('DELETE FROM sessions WHERE expires_at <= $1', [now]);
  return { changes: result.rowCount };
}

// Prune old snapshots (older than 90 days)
async function pruneOldSnapshots() {
  const cutoffTimestamp = Math.floor(Date.now() / 1000) - (90 * 24 * 3600);
  const result = await pool.query('DELETE FROM snapshots WHERE received_at < $1', [cutoffTimestamp]);
  return { changes: result.rowCount };
}

// Run pruning once on startup and then periodically
(async () => {
  await pruneOldSnapshots();
  await pruneExpiredSessions();
})();

setInterval(async () => {
  await pruneOldSnapshots();
  await pruneExpiredSessions();
}, 24 * 60 * 60 * 1000); // Once per day

module.exports = {
  pool,
  upsertAccount,
  addSnapshot,
  getLatestSnapshot,
  getHistory,
  getAllAccounts,
  getAccountInfo,
  deleteAccount,
  createSession,
  verifySession,
  deleteSession,
  pruneOldSnapshots
};
