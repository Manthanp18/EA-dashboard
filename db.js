const Database = require('better-sqlite3');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');

const dbPath = process.env.DB_PATH || './data/mt5.db';
const dbDir = path.dirname(dbPath);

console.log('=== DATABASE INITIALIZATION ===');
console.log('DB_PATH from env:', process.env.DB_PATH);
console.log('Resolved DB path:', dbPath);
console.log('DB directory:', dbDir);

// Ensure data directory exists
if (!fs.existsSync(dbDir)) {
  console.log('Creating DB directory:', dbDir);
  fs.mkdirSync(dbDir, { recursive: true });
} else {
  console.log('DB directory already exists');
}

const db = new Database(dbPath);
db.pragma('journal_mode = WAL');

console.log('Database initialized successfully at:', dbPath);
console.log('===============================');

// Initialize schema
db.exec(`
  CREATE TABLE IF NOT EXISTS accounts (
    login INTEGER PRIMARY KEY,
    api_key_hash TEXT NOT NULL,
    label TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
  );

  CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    login INTEGER NOT NULL,
    balance REAL NOT NULL,
    equity REAL NOT NULL,
    cycle_net REAL NOT NULL,
    realized_bank REAL NOT NULL,
    floating_pnl REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    server TEXT,
    ea_timestamp INTEGER,
    received_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    FOREIGN KEY (login) REFERENCES accounts(login)
  );

  CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    expires_at INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_snapshots_login ON snapshots(login);
  CREATE INDEX IF NOT EXISTS idx_snapshots_received_at ON snapshots(received_at);
  CREATE INDEX IF NOT EXISTS idx_snapshots_login_received ON snapshots(login, received_at DESC);
  CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
`);

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
function addAccount(login, apiKey, label) {
  const apiKeyHash = hashApiKey(apiKey);
  const stmt = db.prepare('INSERT INTO accounts (login, api_key_hash, label) VALUES (?, ?, ?)');
  const result = stmt.run(login, apiKeyHash, label);
  console.log(`✅ Account added: login=${login}, label="${label}"`);
  return result;
}

// Verify account API key
function verifyAccount(login, apiKey) {
  const stmt = db.prepare('SELECT api_key_hash FROM accounts WHERE login = ?');
  const account = stmt.get(login);

  if (!account) {
    return false;
  }

  try {
    return compareApiKey(apiKey, account.api_key_hash);
  } catch (err) {
    return false;
  }
}

// Add a snapshot (with rate limiting - max once per 15 seconds per account)
function addSnapshot(login, data) {
  const now = Math.floor(Date.now() / 1000);

  // Check if we have a recent snapshot (within last 15 seconds)
  const checkStmt = db.prepare(
    'SELECT received_at FROM snapshots WHERE login = ? ORDER BY received_at DESC LIMIT 1'
  );
  const lastSnapshot = checkStmt.get(login);

  if (lastSnapshot && (now - lastSnapshot.received_at) < 15) {
    return null; // Skip this snapshot
  }

  const stmt = db.prepare(`
    INSERT INTO snapshots (login, balance, equity, cycle_net, realized_bank, floating_pnl, currency, server, ea_timestamp, received_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  return stmt.run(
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
  );
}

// Get latest snapshot for an account
function getLatestSnapshot(login) {
  const stmt = db.prepare(`
    SELECT * FROM snapshots
    WHERE login = ?
    ORDER BY received_at DESC
    LIMIT 1
  `);
  return stmt.get(login);
}

// Get historical snapshots
function getHistory(login, hours = 24) {
  const sinceTimestamp = Math.floor(Date.now() / 1000) - (hours * 3600);
  const stmt = db.prepare(`
    SELECT * FROM snapshots
    WHERE login = ? AND received_at >= ?
    ORDER BY received_at ASC
  `);
  return stmt.all(login, sinceTimestamp);
}

// Get all accounts with their latest snapshots
function getAllAccounts() {
  const stmt = db.prepare(`
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
    LEFT JOIN (
      SELECT s1.*
      FROM snapshots s1
      INNER JOIN (
        SELECT login, MAX(received_at) as max_received
        FROM snapshots
        GROUP BY login
      ) s2 ON s1.login = s2.login AND s1.received_at = s2.max_received
    ) s ON a.login = s.login
    ORDER BY a.login
  `);
  const accounts = stmt.all();
  console.log(`📊 getAllAccounts() returned ${accounts.length} account(s)`);
  return accounts;
}

// Get account info by login
function getAccountInfo(login) {
  const stmt = db.prepare('SELECT login, label, created_at FROM accounts WHERE login = ?');
  return stmt.get(login);
}

// Delete account and its snapshots
function deleteAccount(login) {
  const deleteSnapshots = db.prepare('DELETE FROM snapshots WHERE login = ?');
  const deleteAccount = db.prepare('DELETE FROM accounts WHERE login = ?');

  deleteSnapshots.run(login);
  return deleteAccount.run(login);
}

// Session management
function createSession(token) {
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + (30 * 24 * 3600); // 30 days
  const stmt = db.prepare('INSERT INTO sessions (token, created_at, expires_at) VALUES (?, ?, ?)');
  return stmt.run(token, now, expiresAt);
}

function verifySession(token) {
  const now = Math.floor(Date.now() / 1000);
  const stmt = db.prepare('SELECT * FROM sessions WHERE token = ? AND expires_at > ?');
  return stmt.get(token, now) !== undefined;
}

function deleteSession(token) {
  const stmt = db.prepare('DELETE FROM sessions WHERE token = ?');
  return stmt.run(token);
}

function pruneExpiredSessions() {
  const now = Math.floor(Date.now() / 1000);
  const stmt = db.prepare('DELETE FROM sessions WHERE expires_at <= ?');
  return stmt.run(now);
}

// Prune old snapshots (older than 90 days)
function pruneOldSnapshots() {
  const cutoffTimestamp = Math.floor(Date.now() / 1000) - (90 * 24 * 3600);
  const stmt = db.prepare('DELETE FROM snapshots WHERE received_at < ?');
  return stmt.run(cutoffTimestamp);
}

// Run pruning once on startup and then periodically
pruneOldSnapshots();
pruneExpiredSessions();
setInterval(() => {
  pruneOldSnapshots();
  pruneExpiredSessions();
}, 24 * 60 * 60 * 1000); // Once per day

module.exports = {
  db,
  hashApiKey,
  addAccount,
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
