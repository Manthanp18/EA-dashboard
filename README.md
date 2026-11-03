# MT5 Multi-Account Dashboard

Real-time web dashboard for monitoring multiple MT5 Expert Advisor accounts with live metrics including running PnL, equity, balance, and net bank.

## Features

- **Multi-Account Monitoring**: Monitor unlimited MT5 accounts from a single dashboard
- **One-Time Login**: Login once with a master password, manage all accounts
- **Live Metrics**: Real-time display of running PnL, equity, balance, and net bank for each account
- **Status Monitoring**: Online/offline indicator based on last EA push
- **Historical Charts**: Click any account to view equity and net bank over time (1H / 24H / 7D)
- **Easy Account Management**: Add/remove accounts directly from the dashboard UI
- **Secure Authentication**: Master password + API keys per account (no MT5 passwords stored)
- **Auto-pruning**: Keeps last 90 days of data, saves max 1 snapshot per 15 seconds

## Quick Start

### 1. Install Dependencies

```bash
npm install
```

### 2. Configure Environment

```bash
cp .env.example .env
nano .env
```

Set your dashboard password:

```env
PORT=8000
DB_PATH=./data/mt5.db
DASHBOARD_PASSWORD=YOUR_SECURE_PASSWORD_HERE  # Change this!
RATE_LIMIT_PUSH=60
RATE_LIMIT_STATE=120
```

### 3. Start the Server

```bash
node server.js
```

Visit `http://localhost:8000`

### 4. Login to Dashboard

Use the dashboard password from your `.env` file:

```
Password: YOUR_SECURE_PASSWORD_HERE
```

### 5. Add Your First Account

1. Click **"+ Add Account"**
2. Enter MT5 account number and label
3. **SAVE THE API KEY** shown (it won't be shown again!)
4. Configure your EA with this API key

## MT5 EA Configuration

### 1. Copy Modified EA to MT5

Place `Straddle1.1.v1.60 (2).mq5` in:

```
File > Open Data Folder > MQL5 > Experts
```

### 2. Compile

Open MetaEditor (F4) and compile the EA.

### 3. Whitelist API URL

**CRITICAL**: MT5 blocks WebRequest by default.

1. Tools > Options > Expert Advisors
2. Check "Allow WebRequest for listed URL"
3. Add: `http://localhost:8000/api/push` (or your production URL)
4. Click OK

### 4. Configure EA Inputs

| Input | Value | Description |
|-------|-------|-------------|
| **InpApiUrl** | `http://localhost:8000/api/push` | Your dashboard API endpoint |
| **InpApiKey** | (from dashboard) | API key from "+ Add Account" |
| **InpPushSeconds** | `5` | Push interval (minimum 1 second) |
| **InpMagicFilter** | `0` | 0 = all positions, >0 = specific magic |

## Dashboard Usage

### Main Dashboard

After logging in, you'll see all your accounts in a grid:

- **Account Cards**: Each card shows live metrics for one MT5 account
- **Green Badge**: EA Online (pushed data within last 30 seconds)
- **Gray Badge**: EA Offline (no push in 30+ seconds)
- **Auto-Refresh**: Dashboard updates every 3 seconds

### View Account Details

Click any account card to view:

- Historical chart (Equity + Net Bank)
- Time range selector (1H / 24H / 7D)

### Add New Account

1. Click **"+ Add Account"**
2. Enter:
   - **MT5 Account Number**: Your MT5 login
   - **Label**: Friendly name (e.g., "Live Account", "Demo EUR/USD")
3. Click **"Add Account"**
4. **SAVE THE API KEY** immediately
5. Configure your EA with this API key

### Remove Account

Currently via backend only:

```bash
# Using node CLI (add this script later)
# Or direct SQL
sqlite3 data/mt5.db "DELETE FROM accounts WHERE login = 12345678"
```

## Deployment

### Option 1: pm2 + Caddy (Recommended)

```bash
# Install pm2
npm install -g pm2

# Start app
pm2 start ecosystem.config.js
pm2 save
pm2 startup

# Install Caddy (Ubuntu/Debian)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy

# Configure Caddy
sudo cp Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile  # Edit domain
sudo systemctl enable caddy
sudo systemctl start caddy
```

### Option 2: pm2 + Nginx

```bash
# Install Nginx
sudo apt install -y nginx certbot python3-certbot-nginx

# Configure
sudo cp nginx.conf.example /etc/nginx/sites-available/mt5-dashboard
sudo nano /etc/nginx/sites-available/mt5-dashboard  # Edit domain
sudo ln -s /etc/nginx/sites-available/mt5-dashboard /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Get SSL
sudo certbot --nginx -d yourdomain.com

# Start app
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

## API Reference

### Dashboard Endpoints (require session token)

#### POST /api/dashboard/login

Login with master password, get session token.

**Request:**
```json
{
  "password": "your_dashboard_password"
}
```

**Response:**
```json
{
  "token": "088039b762270c918f7b52f5be27a54073a3b764e34f6ab0febd5492ded8c4f9"
}
```

Use this token in `X-Session-Token` header for all dashboard endpoints.

#### GET /api/dashboard/accounts

Get all accounts with latest state.

**Headers:**
- `X-Session-Token`: (from login)

**Response:**
```json
{
  "accounts": [
    {
      "login": 12345678,
      "label": "Live Account",
      "balance": 10000.50,
      "equity": 10250.75,
      "running_pnl": 250.25,
      "net_bank": 9800.00,
      "currency": "USD",
      "server": "Broker-Live",
      "is_online": true,
      "last_update": 1793716021
    }
  ]
}
```

#### POST /api/dashboard/accounts

Add new account to monitor.

**Headers:**
- `X-Session-Token`: (from login)

**Request:**
```json
{
  "login": 87654321,
  "label": "Demo Account"
}
```

**Response:**
```json
{
  "login": 87654321,
  "label": "Demo Account",
  "api_key": "7a4098dcc0d8a93177a478df54930fe63412d38a5478926ba11f0947d2f07550",
  "message": "Account created. Save the API key - it will not be shown again."
}
```

#### GET /api/dashboard/history/:login?hours=24

Get historical snapshots for an account.

**Headers:**
- `X-Session-Token`: (from login)

**Response:**
```json
{
  "login": 12345678,
  "hours": 24,
  "count": 120,
  "snapshots": [...]
}
```

### EA Push Endpoint (uses API key)

#### POST /api/push

EA pushes metrics here (every 5 seconds).

**Headers:**
- `X-API-Key`: (account's API key)
- `Content-Type`: application/json

**Request:**
```json
{
  "login": 12345678,
  "server": "Broker-Live",
  "balance": 10000.50,
  "equity": 10250.75,
  "running_pnl": 250.25,
  "net_bank": 9800.00,
  "currency": "USD",
  "ts": 1730000000
}
```

**Response:**
```json
{
  "status": "ok",
  "snapshot_id": 1
}
```

## Troubleshooting

### EA not pushing data

1. **MT5 Journal errors**:
   - Error 4060: URL not whitelisted → Add URL in Tools > Options
   - Other errors: Check API URL and API key match

2. **WebRequest doesn't work in Strategy Tester** (this is normal)

### Dashboard shows "EA Offline"

- Check EA is running
- Verify `InpApiUrl` and `InpApiKey` match dashboard
- Check backend: `pm2 status` and `pm2 logs`

### Can't login to dashboard

- Check `DASHBOARD_PASSWORD` in `.env`
- Default password: `changeme123`

### How to change dashboard password

```bash
nano .env  # Edit DASHBOARD_PASSWORD
pm2 restart mt5-dashboard
```

### How to add account via CLI

You can still use the CLI script:

```bash
node add-account.js 12345678 "My Account"
```

But the dashboard UI is easier!

## Security

- Dashboard password: Simple password auth (change in `.env`)
- API keys: SHA-256 hashed, timing-safe comparison
- Sessions: 30-day expiry, stored in SQLite
- HTTPS: Required for production (Caddy/Nginx handle this)
- Never commit `.env` or `data/*.db`

## Maintenance

```bash
# View logs
pm2 logs mt5-dashboard

# Restart
pm2 restart mt5-dashboard

# Update code
git pull  # or copy new files
npm install
pm2 restart mt5-dashboard

# Database size
du -h data/mt5.db

# Vacuum database
sqlite3 data/mt5.db "VACUUM;"
```

## License

MIT
