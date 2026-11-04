const crypto = require('crypto');

// Determine which database to use
const DATABASE_URL = process.env.DATABASE_URL;
const USE_POSTGRES = !!DATABASE_URL;

let pool, db;

console.log('=== DATABASE INITIALIZATION ===');

if (USE_POSTGRES) {
  // PostgreSQL mode (production)
  const { Pool } = require('pg');
  console.log('Database: PostgreSQL');

  pool = new Pool({
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
} else {
  // SQLite mode (local development)
  const Database = require('better-sqlite3');
  const fs = require('fs');
  const path = require('path');

  const dataDir = path.join(__dirname, 'data');
  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }

  const dbPath = path.join(dataDir, 'mt5.db');
  console.log('Database: SQLite');
  console.log('Database path:', dbPath);

  db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  console.log('✅ SQLite database opened');
}

console.log('===============================');

// Initialize schema
async function initializeSchema() {
  try {
    if (USE_POSTGRES) {
      // Create tables with base schema
      await pool.query(`
        CREATE TABLE IF NOT EXISTS accounts (
          login BIGINT PRIMARY KEY,
          label TEXT NOT NULL,
          created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT
        );

        CREATE TABLE IF NOT EXISTS snapshots (
          id SERIAL PRIMARY KEY,
          login BIGINT NOT NULL,
          balance REAL NOT NULL,
          equity REAL NOT NULL,
          cycle_net REAL NOT NULL,
          cycle_realized_bank REAL NOT NULL,
          cycle_floating REAL NOT NULL,
          received_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
          FOREIGN KEY (login) REFERENCES accounts(login)
        );

        CREATE TABLE IF NOT EXISTS sessions (
          token TEXT PRIMARY KEY,
          created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
          expires_at BIGINT NOT NULL
        );
      `);

      // Migrate existing schema to add new columns (safe - won't fail if columns exist)
      await pool.query(`
        -- Remove old api_key_hash column (we don't use API keys anymore)
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='accounts' AND column_name='api_key_hash') THEN
            ALTER TABLE accounts DROP COLUMN api_key_hash;
          END IF;
        END $$;

        -- Add last_seen_at to accounts if missing
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='accounts' AND column_name='last_seen_at') THEN
            ALTER TABLE accounts ADD COLUMN last_seen_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT;
          END IF;
        END $$;

        -- Add new snapshot columns if missing
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='schema_version') THEN
            ALTER TABLE snapshots ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='snapshot_id') THEN
            ALTER TABLE snapshots ADD COLUMN snapshot_id TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='sampled_at_utc') THEN
            ALTER TABLE snapshots ADD COLUMN sampled_at_utc TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='source_mode') THEN
            ALTER TABLE snapshots ADD COLUMN source_mode TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='account_name') THEN
            ALTER TABLE snapshots ADD COLUMN account_name TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='server') THEN
            ALTER TABLE snapshots ADD COLUMN server TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='currency') THEN
            ALTER TABLE snapshots ADD COLUMN currency TEXT NOT NULL DEFAULT 'USD';
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_name') THEN
            ALTER TABLE snapshots ADD COLUMN ea_name TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_version') THEN
            ALTER TABLE snapshots ADD COLUMN ea_version TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_instance_id') THEN
            ALTER TABLE snapshots ADD COLUMN ea_instance_id TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_symbol') THEN
            ALTER TABLE snapshots ADD COLUMN ea_symbol TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_magic') THEN
            ALTER TABLE snapshots ADD COLUMN ea_magic TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='ea_status') THEN
            ALTER TABLE snapshots ADD COLUMN ea_status TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_id') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_id TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_active') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_active BOOLEAN;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_active_target') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_active_target REAL;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_profit_basis') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_profit_basis TEXT;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_open_positions') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_open_positions INTEGER;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_pending_orders') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_pending_orders INTEGER;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='snapshots' AND column_name='cycle_accounting_confirmed') THEN
            ALTER TABLE snapshots ADD COLUMN cycle_accounting_confirmed BOOLEAN;
          END IF;
        END $$;

        -- Create indexes
        CREATE INDEX IF NOT EXISTS idx_snapshots_login ON snapshots(login);
        CREATE INDEX IF NOT EXISTS idx_snapshots_received_at ON snapshots(received_at);
        CREATE INDEX IF NOT EXISTS idx_snapshots_login_received ON snapshots(login, received_at DESC);
        CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
      `);
    } else {
      // SQLite schema
      db.exec(`
        CREATE TABLE IF NOT EXISTS accounts (
          login INTEGER PRIMARY KEY,
          label TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
          last_seen_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        );

        CREATE TABLE IF NOT EXISTS snapshots (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          login INTEGER NOT NULL,

          schema_version INTEGER NOT NULL DEFAULT 1,
          snapshot_id TEXT,
          sampled_at_utc TEXT,
          source_mode TEXT,

          account_name TEXT,
          server TEXT,
          currency TEXT NOT NULL DEFAULT 'USD',
          balance REAL NOT NULL,
          equity REAL NOT NULL,

          ea_name TEXT,
          ea_version TEXT,
          ea_instance_id TEXT,
          ea_symbol TEXT,
          ea_magic TEXT,
          ea_status TEXT,

          cycle_id TEXT,
          cycle_active INTEGER,
          cycle_net REAL NOT NULL,
          cycle_realized_bank REAL NOT NULL,
          cycle_floating REAL NOT NULL,
          cycle_active_target REAL,
          cycle_profit_basis TEXT,
          cycle_open_positions INTEGER,
          cycle_pending_orders INTEGER,
          cycle_accounting_confirmed INTEGER,

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
    }

    console.log('✅ Database schema initialized');
  } catch (err) {
    console.error('❌ Schema initialization error:', err.message);
    throw err;
  }
}

// Initialize schema on startup
initializeSchema().catch(err => {
  console.error('Fatal error during schema initialization:', err);
  process.exit(1);
});

// Auto-create or update account when EA sends data
async function upsertAccount(login, label) {
  const now = Math.floor(Date.now() / 1000);

  if (USE_POSTGRES) {
    const result = await pool.query(
      `INSERT INTO accounts (login, label, created_at, last_seen_at)
       VALUES ($1, $2, $3, $3)
       ON CONFLICT (login)
       DO UPDATE SET label = $2, last_seen_at = $3
       RETURNING *`,
      [login, label || `Account ${login}`, now]
    );
    return result.rows[0];
  } else {
    const stmt = db.prepare(`
      INSERT INTO accounts (login, label, created_at, last_seen_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(login) DO UPDATE SET label = ?, last_seen_at = ?
    `);
    stmt.run(login, label || `Account ${login}`, now, now, label || `Account ${login}`, now);
    return db.prepare('SELECT * FROM accounts WHERE login = ?').get(login);
  }
}

// Add a snapshot (with rate limiting - max once per 15 seconds per account)
async function addSnapshot(login, data) {
  const now = Math.floor(Date.now() / 1000);

  if (USE_POSTGRES) {
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
  } else {
    // SQLite version
    const lastSnapshot = db.prepare(
      'SELECT received_at FROM snapshots WHERE login = ? ORDER BY received_at DESC LIMIT 1'
    ).get(login);

    if (lastSnapshot && (now - lastSnapshot.received_at) < 15) {
      return null; // Skip this snapshot
    }

    const stmt = db.prepare(`
      INSERT INTO snapshots (
        login, schema_version, snapshot_id, sampled_at_utc, source_mode,
        account_name, server, currency, balance, equity,
        ea_name, ea_version, ea_instance_id, ea_symbol, ea_magic, ea_status,
        cycle_id, cycle_active, cycle_net, cycle_realized_bank, cycle_floating,
        cycle_active_target, cycle_profit_basis, cycle_open_positions,
        cycle_pending_orders, cycle_accounting_confirmed, received_at
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
    `);

    const info = stmt.run(
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
      data.cycle?.active ? 1 : 0,
      data.cycle?.net || 0,
      data.cycle?.realized_bank || 0,
      data.cycle?.floating || 0,
      data.cycle?.active_target || null,
      data.cycle?.profit_basis || null,
      data.cycle?.open_positions || null,
      data.cycle?.pending_orders || null,
      data.cycle?.accounting_confirmed ? 1 : 0,
      now
    );

    return db.prepare('SELECT * FROM snapshots WHERE id = ?').get(info.lastInsertRowid);
  }
}

// Get latest snapshot for an account
async function getLatestSnapshot(login) {
  if (USE_POSTGRES) {
    const result = await pool.query(
      `SELECT * FROM snapshots
       WHERE login = $1
       ORDER BY received_at DESC
       LIMIT 1`,
      [login]
    );
    return result.rows[0];
  } else {
    return db.prepare(
      'SELECT * FROM snapshots WHERE login = ? ORDER BY received_at DESC LIMIT 1'
    ).get(login);
  }
}

// Get historical snapshots
async function getHistory(login, hours = 24) {
  const sinceTimestamp = Math.floor(Date.now() / 1000) - (hours * 3600);

  if (USE_POSTGRES) {
    const result = await pool.query(
      `SELECT * FROM snapshots
       WHERE login = $1 AND received_at >= $2
       ORDER BY received_at ASC`,
      [login, sinceTimestamp]
    );
    return result.rows;
  } else {
    return db.prepare(
      'SELECT * FROM snapshots WHERE login = ? AND received_at >= ? ORDER BY received_at ASC'
    ).all(login, sinceTimestamp);
  }
}

// Get all accounts with their latest snapshots
async function getAllAccounts() {
  if (USE_POSTGRES) {
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
  } else {
    // SQLite version
    const accounts = db.prepare(`
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
      LEFT JOIN (
        SELECT *
        FROM snapshots s1
        WHERE s1.id = (
          SELECT s2.id
          FROM snapshots s2
          WHERE s2.login = a.login
          ORDER BY s2.received_at DESC
          LIMIT 1
        )
      ) s ON a.login = s.login
      ORDER BY a.last_seen_at DESC
    `).all();

    console.log(`📊 getAllAccounts() returned ${accounts.length} account(s)`);
    if (accounts.length > 0) {
      accounts.forEach(acc => {
        console.log(`   - Login: ${acc.login}, Label: "${acc.label}", EA: ${acc.ea_name || 'N/A'}`);
      });
    }
    return accounts;
  }
}

// Get account info by login
async function getAccountInfo(login) {
  if (USE_POSTGRES) {
    const result = await pool.query(
      'SELECT login, label, created_at FROM accounts WHERE login = $1',
      [login]
    );
    return result.rows[0];
  } else {
    return db.prepare('SELECT login, label, created_at FROM accounts WHERE login = ?').get(login);
  }
}

// Delete account and its snapshots
async function deleteAccount(login) {
  if (USE_POSTGRES) {
    await pool.query('DELETE FROM snapshots WHERE login = $1', [login]);
    const result = await pool.query('DELETE FROM accounts WHERE login = $1', [login]);
    return { changes: result.rowCount };
  } else {
    db.prepare('DELETE FROM snapshots WHERE login = ?').run(login);
    const info = db.prepare('DELETE FROM accounts WHERE login = ?').run(login);
    return { changes: info.changes };
  }
}

// Session management
async function createSession(token) {
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + (30 * 24 * 3600); // 30 days

  if (USE_POSTGRES) {
    const result = await pool.query(
      'INSERT INTO sessions (token, created_at, expires_at) VALUES ($1, $2, $3) RETURNING *',
      [token, now, expiresAt]
    );
    return result.rows[0];
  } else {
    db.prepare('INSERT INTO sessions (token, created_at, expires_at) VALUES (?, ?, ?)').run(token, now, expiresAt);
    return db.prepare('SELECT * FROM sessions WHERE token = ?').get(token);
  }
}

async function verifySession(token) {
  const now = Math.floor(Date.now() / 1000);

  if (USE_POSTGRES) {
    const result = await pool.query(
      'SELECT * FROM sessions WHERE token = $1 AND expires_at > $2',
      [token, now]
    );
    return result.rows.length > 0;
  } else {
    const session = db.prepare('SELECT * FROM sessions WHERE token = ? AND expires_at > ?').get(token, now);
    return !!session;
  }
}

async function deleteSession(token) {
  if (USE_POSTGRES) {
    const result = await pool.query('DELETE FROM sessions WHERE token = $1', [token]);
    return { changes: result.rowCount };
  } else {
    const info = db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
    return { changes: info.changes };
  }
}

async function pruneExpiredSessions() {
  const now = Math.floor(Date.now() / 1000);

  if (USE_POSTGRES) {
    const result = await pool.query('DELETE FROM sessions WHERE expires_at <= $1', [now]);
    return { changes: result.rowCount };
  } else {
    const info = db.prepare('DELETE FROM sessions WHERE expires_at <= ?').run(now);
    return { changes: info.changes };
  }
}

// Prune old snapshots (older than 90 days)
async function pruneOldSnapshots() {
  const cutoffTimestamp = Math.floor(Date.now() / 1000) - (90 * 24 * 3600);

  if (USE_POSTGRES) {
    const result = await pool.query('DELETE FROM snapshots WHERE received_at < $1', [cutoffTimestamp]);
    return { changes: result.rowCount };
  } else {
    const info = db.prepare('DELETE FROM snapshots WHERE received_at < ?').run(cutoffTimestamp);
    return { changes: info.changes };
  }
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
  db,
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
