require('dotenv').config();
const express = require('express');
const rateLimit = require('express-rate-limit');
const path = require('path');
const crypto = require('crypto');
const {
  verifyAccount,
  addSnapshot,
  getLatestSnapshot,
  getHistory,
  getAllAccounts,
  getAccountInfo,
  addAccount,
  updateAccountLabel,
  deleteAccount,
  createSession,
  verifySession,
  deleteSession
} = require('./db');

const app = express();
const PORT = process.env.PORT || 8000;
const DASHBOARD_PASSWORD = process.env.DASHBOARD_PASSWORD || 'changeme123';

// Trust proxy for Render (fixes rate limiter behind reverse proxy)
app.set('trust proxy', 1);

// SSE: Track active dashboard connections
const sseClients = new Set();

// SSE: Broadcast account update to all connected dashboards
function broadcastAccountUpdate(login) {
  if (sseClients.size === 0) return;

  try {
    const accounts = getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    const data = JSON.stringify({ accounts: enrichedAccounts });

    sseClients.forEach(client => {
      try {
        client.write(`data: ${data}\n\n`);
      } catch (err) {
        sseClients.delete(client);
      }
    });
  } catch (err) {
    console.error('Error broadcasting SSE update:', err);
  }
}

// Middleware
app.use(express.json());

// Rate limiters
const pushLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: parseInt(process.env.RATE_LIMIT_PUSH || '60', 10),
  message: { error: 'Too many requests from EA, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

const dashboardLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: parseInt(process.env.RATE_LIMIT_STATE || '120', 10),
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

// Session middleware
function requireAuth(req, res, next) {
  // Check header first, then query param (for SSE)
  const token = req.headers['x-session-token'] || req.query.token;

  if (!token) {
    return res.status(401).json({ error: 'Missing session token' });
  }

  if (!verifySession(token)) {
    return res.status(401).json({ error: 'Invalid or expired session' });
  }

  next();
}

// Validation helper
function validateNumber(value, name, allowNegative = true) {
  if (typeof value !== 'number' || isNaN(value) || !isFinite(value)) {
    throw new Error(`${name} must be a valid number`);
  }
  if (!allowNegative && value < 0) {
    throw new Error(`${name} cannot be negative`);
  }
  return value;
}

// POST /api/push - EA pushes data here (no session required, uses API key)
app.post('/api/push', pushLimiter, (req, res) => {
  try {
    const apiKey = req.headers['x-api-key'];

    if (!apiKey) {
      return res.status(401).json({ error: 'Missing X-API-Key header' });
    }

    const { login, server, account_name, balance, equity, cycle_net, realized_bank, floating_pnl, currency, ts } = req.body;

    if (!login || typeof login !== 'number' || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    if (!verifyAccount(login, apiKey)) {
      return res.status(401).json({ error: 'Invalid API key' });
    }

    // Auto-update account label if account_name is provided by EA
    if (account_name && typeof account_name === 'string' && account_name.trim().length > 0) {
      try {
        updateAccountLabel(login, account_name.trim());
      } catch (err) {
        console.error(`Error updating account label for ${login}:`, err.message);
      }
    }

    try {
      validateNumber(balance, 'balance', false);
      validateNumber(equity, 'equity', false);
      validateNumber(cycle_net, 'cycle_net');
      validateNumber(realized_bank, 'realized_bank');
      validateNumber(floating_pnl, 'floating_pnl');
      if (ts !== undefined) {
        validateNumber(ts, 'ts', false);
      }
    } catch (err) {
      return res.status(400).json({ error: err.message });
    }

    const result = addSnapshot(login, {
      balance,
      equity,
      cycle_net,
      realized_bank,
      floating_pnl,
      currency: currency || 'USD',
      server: server || null,
      ts: ts || null
    });

    if (result === null) {
      return res.status(202).json({ status: 'accepted', message: 'Snapshot received but rate-limited' });
    }

    // Broadcast update to all connected dashboards via SSE
    broadcastAccountUpdate(login);

    res.status(200).json({ status: 'ok', snapshot_id: result.lastInsertRowid });
  } catch (err) {
    console.error('Error in /api/push:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/dashboard/login - Dashboard login with master password
app.post('/api/dashboard/login', dashboardLimiter, (req, res) => {
  try {
    const { password } = req.body;

    if (!password) {
      return res.status(400).json({ error: 'Password required' });
    }

    if (password !== DASHBOARD_PASSWORD) {
      return res.status(401).json({ error: 'Invalid password' });
    }

    // Generate session token
    const token = crypto.randomBytes(32).toString('hex');
    createSession(token);

    res.status(200).json({ token });
  } catch (err) {
    console.error('Error in /api/dashboard/login:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/dashboard/logout
app.post('/api/dashboard/logout', (req, res) => {
  try {
    const token = req.headers['x-session-token'];
    if (token) {
      deleteSession(token);
    }
    res.status(200).json({ status: 'ok' });
  } catch (err) {
    console.error('Error in /api/dashboard/logout:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/dashboard/stream - Server-Sent Events for real-time updates
app.get('/api/dashboard/stream', requireAuth, (req, res) => {
  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering

  // Add this client to active connections
  sseClients.add(res);

  // Send initial data
  try {
    const accounts = getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    res.write(`data: ${JSON.stringify({ accounts: enrichedAccounts })}\n\n`);
  } catch (err) {
    console.error('Error sending initial SSE data:', err);
  }

  // Send heartbeat every 30 seconds to keep connection alive
  const heartbeat = setInterval(() => {
    res.write(': heartbeat\n\n');
  }, 30000);

  // Remove client when connection closes
  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
  });
});

// GET /api/dashboard/accounts - Get all accounts with latest state
app.get('/api/dashboard/accounts', requireAuth, dashboardLimiter, (req, res) => {
  try {
    const accounts = getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    res.status(200).json({ accounts: enrichedAccounts });
  } catch (err) {
    console.error('Error in /api/dashboard/accounts:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/dashboard/accounts - Add new account to monitor
app.post('/api/dashboard/accounts', requireAuth, dashboardLimiter, (req, res) => {
  try {
    const { login, label } = req.body;

    if (!login || typeof login !== 'number' || login <= 0) {
      return res.status(400).json({ error: 'Invalid login (must be positive integer)' });
    }

    if (!label || typeof label !== 'string' || label.trim().length === 0) {
      return res.status(400).json({ error: 'Label required' });
    }

    // Generate API key
    const apiKey = crypto.randomBytes(32).toString('hex');

    try {
      addAccount(login, apiKey, label.trim());
    } catch (err) {
      if (err.code === 'SQLITE_CONSTRAINT') {
        return res.status(409).json({ error: 'Account already exists' });
      }
      throw err;
    }

    res.status(201).json({
      login,
      label: label.trim(),
      api_key: apiKey,
      message: 'Account created. Save the API key - it will not be shown again.'
    });
  } catch (err) {
    console.error('Error in POST /api/dashboard/accounts:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /api/dashboard/accounts/:login - Remove account
app.delete('/api/dashboard/accounts/:login', requireAuth, dashboardLimiter, (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    const result = deleteAccount(login);

    if (result.changes === 0) {
      return res.status(404).json({ error: 'Account not found' });
    }

    res.status(200).json({ status: 'ok', message: 'Account deleted' });
  } catch (err) {
    console.error('Error in DELETE /api/dashboard/accounts:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/dashboard/state/:login - Get latest state for specific account
app.get('/api/dashboard/state/:login', requireAuth, dashboardLimiter, (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    const snapshot = getLatestSnapshot(login);

    if (!snapshot) {
      return res.status(404).json({ error: 'No data available for this account' });
    }

    const now = Math.floor(Date.now() / 1000);
    const isOnline = (now - snapshot.received_at) < 30;

    res.status(200).json({
      ...snapshot,
      is_online: isOnline
    });
  } catch (err) {
    console.error('Error in /api/dashboard/state:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/dashboard/history/:login - Get historical snapshots
app.get('/api/dashboard/history/:login', requireAuth, dashboardLimiter, (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);
    const hours = parseInt(req.query.hours, 10) || 24;

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    if (hours <= 0 || hours > 168) {
      return res.status(400).json({ error: 'Hours must be between 1 and 168' });
    }

    const snapshots = getHistory(login, hours);

    res.status(200).json({
      login,
      hours,
      count: snapshots.length,
      snapshots
    });
  } catch (err) {
    console.error('Error in /api/dashboard/history:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Serve static frontend
app.use(express.static(path.join(__dirname, 'public')));

// Catch-all route for SPA
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start server
app.listen(PORT, () => {
  console.log(`MT5 Dashboard server running on port ${PORT}`);
  console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
  console.log(`Database: ${process.env.DB_PATH || './data/mt5.db'}`);
  console.log(`\nDashboard password: ${DASHBOARD_PASSWORD}`);
  console.log(`\nIMPORTANT: Change DASHBOARD_PASSWORD in .env before deploying!`);
});
