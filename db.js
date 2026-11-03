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
        api_key_hash TEXT NOT NULL,
        label TEXT NOT NULL,
        created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT
      );

      CREATE TABLE IF NOT EXISTS snapshots (
        id SERIAL PRIMARY KEY,
        login BIGINT NOT NULL,
        balance REAL NOT NULL,
        equity REAL NOT NULL,
        cycle_net REAL NOT NULL,
        realized_bank REAL NOT NULL,
        floating_pnl REAL NOT NULL,
        currency TEXT NOT NULL DEFAULT 'USD',
        server TEXT,
        ea_timestamp BIGINT,
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

// Hash API key using SHA-256
function hashApiKey(apiKey) {
  return crypto.createHash('sha256').update(apiKey).digest('hex');
}

// Timing-safe comparison for API keys
function compareApiKey(inputKey, storedHash) {
  const inputHash = hashApiKey(inputKey);
  return crypto.timingSafeEqual(
    Buffer.from(inputHash, 'hex'),
    Buffer.from(storedHash, 'hex')
  );
}

// Add a new account
async function addAccount(login, apiKey, label) {
  const apiKeyHash = hashApiKey(apiKey);
  const result = await pool.query(
    'INSERT INTO accounts (login, api_key_hash, label) VALUES ($1, $2, $3) RETURNING *',
    [login, apiKeyHash, label]
  );
  console.log(`✅ Account added: login=${login}, label="${label}"`);
  return result.rows[0];
}

// Update account label (called when EA sends account_name)
async function updateAccountLabel(login, newLabel) {
  const result = await pool.query(
    'UPDATE accounts SET label = $1 WHERE login = $2',
    [newLabel, login]
  );
  return result;
}

// Verify account API key
async function verifyAccount(login, apiKey) {
  const result = await pool.query(
    'SELECT api_key_hash FROM accounts WHERE login = $1',
    [login]
  );

  if (result.rows.length === 0) {
    return false;
  }

  try {
    return compareApiKey(apiKey, result.rows[0].api_key_hash);
  } catch (err) {
    return false;
  }
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
    `INSERT INTO snapshots (login, balance, equity, cycle_net, realized_bank, floating_pnl, currency, server, ea_timestamp, received_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
    [
      login,
      data.balance,
      data.equity,
      data.cycle_net,
      data.realized_bank,
      data.floating_pnl,
      data.currency || 'USD',
      data.server || null,
      data.ts || null,
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
      s.balance,
      s.equity,
      s.cycle_net,
      s.realized_bank,
      s.floating_pnl,
      s.currency,
      s.server,
      s.received_at
    FROM accounts a
    LEFT JOIN LATERAL (
      SELECT *
      FROM snapshots
      WHERE snapshots.login = a.login
      ORDER BY received_at DESC
      LIMIT 1
    ) s ON true
    ORDER BY a.login
  `);

  const accounts = result.rows;
  console.log(`📊 getAllAccounts() returned ${accounts.length} account(s)`);
  if (accounts.length > 0) {
    accounts.forEach(acc => {
      console.log(`   - Login: ${acc.login}, Label: "${acc.label}"`);
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
  hashApiKey,
  addAccount,
  updateAccountLabel,
  verifyAccount,
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
