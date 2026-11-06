require('dotenv').config();
const express = require('express');
const rateLimit = require('express-rate-limit');
const path = require('path');
const crypto = require('crypto');
const {
  upsertAccount,
  addSnapshot,
  getLatestSnapshot,
  getHistory,
  getAllAccounts,
  getAccountInfo,
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
async function broadcastAccountUpdate(login) {
  if (sseClients.size === 0) return;

  try {
    const accounts = await getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      today_pnl: account.today_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      account_name: account.account_name || null,
      source_mode: account.source_mode || null,
      ea_name: account.ea_name || null,
      ea_version: account.ea_version || null,
      ea_symbol: account.ea_symbol || null,
      ea_magic: account.ea_magic || null,
      ea_status: account.ea_status || null,
      cycle_open_positions: account.cycle_open_positions || 0,
      cycle_pending_orders: account.cycle_pending_orders || 0,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    const data = JSON.stringify({ accounts: enrichedAccounts });

    sseClients.forEach(client => {
      try {
        // Check if the connection is still writable
        if (client.writable) {
          client.write(`data: ${data}\n\n`);
        } else {
          sseClients.delete(client);
        }
      } catch (err) {
        console.error('Error broadcasting to SSE client:', err.message);
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
async function requireAuth(req, res, next) {
  // Check header first, then query param (for SSE)
  const token = req.headers['x-session-token'] || req.query.token;

  if (!token) {
    return res.status(401).json({ error: 'Missing session token' });
  }

  const isValid = await verifySession(token);
  if (!isValid) {
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

// POST /api/push - EA pushes data here (no authentication required)
app.post('/api/push', pushLimiter, async (req, res) => {
  try {
    const data = req.body;

    // Validate required fields
    if (!data.account || !data.account.login) {
      return res.status(400).json({ error: 'Missing account.login' });
    }

    const login = parseInt(data.account.login);
    if (isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid account.login' });
    }

    // Validate numbers
    try {
      if (data.account.balance !== undefined) validateNumber(data.account.balance, 'account.balance', false);
      if (data.account.equity !== undefined) validateNumber(data.account.equity, 'account.equity', false);
      if (data.cycle?.net !== undefined) validateNumber(data.cycle.net, 'cycle.net');
      if (data.cycle?.realized_bank !== undefined) validateNumber(data.cycle.realized_bank, 'cycle.realized_bank');
      if (data.cycle?.floating !== undefined) validateNumber(data.cycle.floating, 'cycle.floating');
    } catch (err) {
      return res.status(400).json({ error: err.message });
    }

    // Auto-create or update account
    const accountLabel = data.account.name || data.ea?.name || `Account ${login}`;
    await upsertAccount(login, accountLabel);

    // Save snapshot
    const result = await addSnapshot(login, data);

    if (result === null) {
      return res.status(202).json({
        status: 'accepted',
        message: 'Snapshot received but rate-limited',
        login: login
      });
    }

    // Broadcast update to all connected dashboards via SSE
    await broadcastAccountUpdate(login);

    res.status(200).json({
      status: 'ok',
      snapshot_id: result.id,
      login: login
    });
  } catch (err) {
    console.error('Error in /api/push:', err);
    res.status(500).json({ error: 'Internal server error', details: err.message });
  }
});

// POST /api/dashboard/login - Dashboard login with master password
app.post('/api/dashboard/login', dashboardLimiter, async (req, res) => {
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
    await createSession(token);

    res.status(200).json({ token });
  } catch (err) {
    console.error('Error in /api/dashboard/login:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/dashboard/logout
app.post('/api/dashboard/logout', async (req, res) => {
  try {
    const token = req.headers['x-session-token'];
    if (token) {
      await deleteSession(token);
    }
    res.status(200).json({ status: 'ok' });
  } catch (err) {
    console.error('Error in /api/dashboard/logout:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/dashboard/stream - Server-Sent Events for real-time updates
app.get('/api/dashboard/stream', requireAuth, async (req, res) => {
  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering
  res.flushHeaders(); // Flush headers immediately to establish connection

  // Add this client to active connections
  sseClients.add(res);

  // Send initial data
  try {
    const accounts = await getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      today_pnl: account.today_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      account_name: account.account_name || null,
      source_mode: account.source_mode || null,
      ea_name: account.ea_name || null,
      ea_version: account.ea_version || null,
      ea_symbol: account.ea_symbol || null,
      ea_magic: account.ea_magic || null,
      ea_status: account.ea_status || null,
      cycle_open_positions: account.cycle_open_positions || 0,
      cycle_pending_orders: account.cycle_pending_orders || 0,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    res.write(`data: ${JSON.stringify({ accounts: enrichedAccounts })}\n\n`);
  } catch (err) {
    console.error('Error sending initial SSE data:', err);
  }

  // Send heartbeat every 15 seconds to keep connection alive (reduced from 30s)
  const heartbeat = setInterval(() => {
    try {
      res.write(': heartbeat\n\n');
    } catch (err) {
      // Connection is dead, clean up
      clearInterval(heartbeat);
      sseClients.delete(res);
    }
  }, 15000);

  // Remove client when connection closes
  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
  });

  // Handle errors on the response stream
  req.on('error', (err) => {
    console.error('SSE request error:', err);
    clearInterval(heartbeat);
    sseClients.delete(res);
  });
});

// GET /api/dashboard/accounts - Get all accounts with latest state
app.get('/api/dashboard/accounts', requireAuth, dashboardLimiter, async (req, res) => {
  try {
    const accounts = await getAllAccounts();
    const now = Math.floor(Date.now() / 1000);

    const enrichedAccounts = accounts.map(account => ({
      login: account.login,
      label: account.label,
      balance: account.balance || 0,
      equity: account.equity || 0,
      cycle_net: account.cycle_net || 0,
      realized_bank: account.realized_bank || 0,
      floating_pnl: account.floating_pnl || 0,
      today_pnl: account.today_pnl || 0,
      currency: account.currency || 'USD',
      server: account.server || null,
      account_name: account.account_name || null,
      source_mode: account.source_mode || null,
      ea_name: account.ea_name || null,
      ea_version: account.ea_version || null,
      ea_symbol: account.ea_symbol || null,
      ea_magic: account.ea_magic || null,
      ea_status: account.ea_status || null,
      cycle_open_positions: account.cycle_open_positions || 0,
      cycle_pending_orders: account.cycle_pending_orders || 0,
      is_online: account.received_at ? (now - account.received_at) < 30 : false,
      last_update: account.received_at || null
    }));

    res.status(200).json({ accounts: enrichedAccounts });
  } catch (err) {
    console.error('Error in /api/dashboard/accounts:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /api/dashboard/accounts - DISABLED (accounts are auto-created by EA)
// app.post('/api/dashboard/accounts', requireAuth, dashboardLimiter, async (req, res) => {
//   res.status(501).json({ error: 'Manual account creation disabled. Accounts are auto-created when EA sends data.' });
// });

// DELETE /api/dashboard/accounts/:login - Remove account
app.delete('/api/dashboard/accounts/:login', requireAuth, dashboardLimiter, async (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    const result = await deleteAccount(login);

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
app.get('/api/dashboard/state/:login', requireAuth, dashboardLimiter, async (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    const snapshot = await getLatestSnapshot(login);

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
app.get('/api/dashboard/history/:login', requireAuth, dashboardLimiter, async (req, res) => {
  try {
    const login = parseInt(req.params.login, 10);
    const hours = parseInt(req.query.hours, 10) || 24;

    if (!login || isNaN(login) || login <= 0) {
      return res.status(400).json({ error: 'Invalid login' });
    }

    if (hours <= 0 || hours > 168) {
      return res.status(400).json({ error: 'Hours must be between 1 and 168' });
    }

    const snapshots = await getHistory(login, hours);

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
  console.log(`\nDashboard password: ${DASHBOARD_PASSWORD}`);
  console.log(`\nIMPORTANT: Change DASHBOARD_PASSWORD in .env before deploying!`);
});
