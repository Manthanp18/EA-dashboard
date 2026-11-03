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

## 🚀 Deploy to Render

### 1. Fork or Import Repository

1. Go to [Render Dashboard](https://dashboard.render.com/)
2. Click **"New +"** → **"Web Service"**
3. Connect your GitHub account
4. Select this repository: `Manthanp18/EA-dashboard`

### 2. Configure Service

Render will auto-detect settings, or enter manually:

- **Name**: `mt5-dashboard`
- **Runtime**: `Node`
- **Build Command**: `npm install`
- **Start Command**: `npm start`

### 3. Add Environment Variables

Click **"Advanced"** and add:

| Key | Value |
|-----|-------|
| `PORT` | `10000` |
| `DB_PATH` | `/opt/render/project/src/data/mt5.db` |
| `DASHBOARD_PASSWORD` | `YourSecurePassword123!` |
| `RATE_LIMIT_PUSH` | `60` |
| `RATE_LIMIT_STATE` | `120` |

### 4. Add Persistent Disk

In **"Advanced"** settings:
- Click **"Add Disk"**
- **Name**: `mt5-data`
- **Mount Path**: `/opt/render/project/src/data`
- **Size**: `1 GB` (free tier)

### 5. Deploy

Click **"Create Web Service"**

Render will:
- ✅ Build your app
- ✅ Deploy with HTTPS automatically
- ✅ Give you a URL like: `https://mt5-dashboard-xxxx.onrender.com`

---

## 📱 Access Your Dashboard

Once deployed, visit your Render URL:
```
https://mt5-dashboard-xxxx.onrender.com
```

Login with the password you set in environment variables.

---

## 🔧 Configure MT5 EA

### 1. Whitelist Your Render URL in MT5

**In MT5:**
1. Tools > Options > Expert Advisors
2. Check "Allow WebRequest for listed URL"
3. Add your Render URL:
   ```
   https://mt5-dashboard-xxxx.onrender.com
   ```
   *(Replace with your actual Render URL)*

### 2. Add Account in Dashboard

1. Visit your dashboard
2. Login with your password
3. Click **"+ Add Account"**
4. Enter:
   - MT5 Account Number
   - Label (friendly name)
5. **SAVE THE API KEY** (shown only once!)

### 3. Configure EA Settings

In MT5, attach your EA and set:

| Input | Value |
|-------|-------|
| **InpApiUrl** | `https://mt5-dashboard-xxxx.onrender.com/api/push` |
| **InpApiKey** | (API key from dashboard) |
| **InpPushSeconds** | `5` |
| **InpMagicFilter** | `0` |

---

## 💻 Local Development

### 1. Clone Repository

```bash
git clone https://github.com/Manthanp18/EA-dashboard.git
cd EA-dashboard
```

### 2. Install Dependencies

```bash
npm install
```

### 3. Configure Environment

```bash
cp .env.example .env
nano .env
```

Set your values:
```env
PORT=8000
DB_PATH=./data/mt5.db
DASHBOARD_PASSWORD=changeme123
RATE_LIMIT_PUSH=60
RATE_LIMIT_STATE=120
```

### 4. Run Locally

```bash
npm start
```

Visit: `http://localhost:8000`

### 5. Add Account via CLI (Optional)

```bash
node add-account.js 12345678 "My Account"
```

Or use the dashboard UI (easier).

---

## 🎯 Usage

### Dashboard Login

- Visit your Render URL
- Enter dashboard password
- See all accounts at once

### Add New Account

1. Click **"+ Add Account"**
2. Enter MT5 login and label
3. Copy the API key
4. Configure EA with that API key

### View Account Details

- Click any account card
- See historical charts
- Toggle time ranges (1H / 24H / 7D)

---

## 🔒 Security

- **Dashboard Password**: Set via environment variable
- **API Keys**: SHA-256 hashed, one per account
- **Sessions**: 30-day expiry
- **HTTPS**: Automatic via Render
- **Never commit**: `.env` or database files

---

## 🐛 Troubleshooting

### EA Not Pushing Data

1. **Check MT5 Journal** for errors
2. **Error 4060**: URL not whitelisted
   - Add Render URL to MT5 whitelist
3. **Check EA Settings**: Verify API URL and key match dashboard

### Dashboard Shows "EA Offline"

- EA must be running with correct API key
- Check Render logs for errors
- Verify dashboard password is correct

### Free Tier Sleep Issue

Render free tier sleeps after 15 minutes of inactivity:
- First request after sleep takes ~30 seconds to wake up
- Upgrade to paid plan ($7/month) for 24/7 uptime
- Or use a free uptime monitor to ping every 10 minutes

---

## 📊 API Reference

### Dashboard Endpoints (require session token)

#### POST /api/dashboard/login
```json
{
  "password": "your_password"
}
```

Returns session token.

#### GET /api/dashboard/accounts
Get all accounts with latest state.

#### POST /api/dashboard/accounts
Add new account, returns API key.

#### GET /api/dashboard/history/:login?hours=24
Get historical data for charts.

### EA Push Endpoint

#### POST /api/push
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

Headers: `X-API-Key: your_api_key`

---

## 🔄 Update Deployment

Render auto-deploys on git push:

```bash
git add .
git commit -m "Update dashboard"
git push origin main
```

Render will rebuild and redeploy automatically!

---

## 📝 Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Server port | `10000` |
| `DB_PATH` | SQLite database path | `./data/mt5.db` (local) or `/opt/render/project/src/data/mt5.db` (Render) |
| `DASHBOARD_PASSWORD` | Master login password | (required) |
| `RATE_LIMIT_PUSH` | EA push rate limit/min | `60` |
| `RATE_LIMIT_STATE` | Dashboard API rate limit/min | `120` |

---

## 📧 Support

- **GitHub Issues**: https://github.com/Manthanp18/EA-dashboard/issues
- **Documentation**: See this README

---

## 📄 License

MIT
