// Session token storage
const SESSION_TOKEN_KEY = 'mt5_session_token';

// DOM Elements
const loginScreen = document.getElementById('loginScreen');
const dashboardScreen = document.getElementById('dashboardScreen');
const loginForm = document.getElementById('loginForm');
const loginError = document.getElementById('loginError');
const logoutBtn = document.getElementById('logoutBtn');
const refreshBtn = document.getElementById('refreshBtn');
const addAccountBtn = document.getElementById('addAccountBtn');
const accountsGrid = document.getElementById('accountsGrid');

// Modals
const chartModal = document.getElementById('chartModal');
const closeModal = document.getElementById('closeModal');
const addAccountModal = document.getElementById('addAccountModal');
const closeAddModal = document.getElementById('closeAddModal');
const addAccountForm = document.getElementById('addAccountForm');
const addAccountError = document.getElementById('addAccountError');
const addAccountSuccess = document.getElementById('addAccountSuccess');
const apiKeyDisplay = document.getElementById('apiKeyDisplay');
const generatedApiKey = document.getElementById('generatedApiKey');
const copyApiKey = document.getElementById('copyApiKey');

// State
let sessionToken = null;
let eventSource = null;
let detailChart = null;
let currentHours = 1;
let currentChartLogin = null;

// Utility Functions
function formatNumber(num, decimals = 2) {
  return num.toFixed(decimals).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function showError(element, message) {
  element.textContent = message;
  element.classList.remove('hidden');
}

function hideError(element) {
  element.classList.add('hidden');
}

function getSessionToken() {
  return sessionStorage.getItem(SESSION_TOKEN_KEY);
}

function setSessionToken(token) {
  sessionToken = token;
  sessionStorage.setItem(SESSION_TOKEN_KEY, token);
}

function clearSessionToken() {
  sessionToken = null;
  sessionStorage.removeItem(SESSION_TOKEN_KEY);
}

// API Functions
async function apiCall(endpoint, options = {}) {
  const headers = {
    'Content-Type': 'application/json',
    ...options.headers
  };

  if (sessionToken && !options.skipAuth) {
    headers['X-Session-Token'] = sessionToken;
  }

  const response = await fetch(endpoint, {
    ...options,
    headers
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ error: 'Request failed' }));
    throw new Error(error.error || `HTTP ${response.status}`);
  }

  return response.json();
}

async function login(password) {
  const data = await apiCall('/api/dashboard/login', {
    method: 'POST',
    body: JSON.stringify({ password }),
    skipAuth: true
  });

  setSessionToken(data.token);
}

async function logout() {
  try {
    await apiCall('/api/dashboard/logout', {
      method: 'POST'
    });
  } catch (err) {
    console.error('Logout error:', err);
  }

  clearSessionToken();
  if (eventSource) {
    eventSource.close();
    eventSource = null;
  }
  showLoginScreen();
}

async function fetchAccounts() {
  return await apiCall('/api/dashboard/accounts');
}

async function addAccount(login, label) {
  return await apiCall('/api/dashboard/accounts', {
    method: 'POST',
    body: JSON.stringify({ login, label })
  });
}

async function deleteAccount(login) {
  return await apiCall(`/api/dashboard/accounts/${login}`, {
    method: 'DELETE'
  });
}

async function fetchHistory(login, hours) {
  return await apiCall(`/api/dashboard/history/${login}?hours=${hours}`);
}

// UI Functions
function showLoginScreen() {
  loginScreen.classList.remove('hidden');
  dashboardScreen.classList.add('hidden');
}

function showDashboardScreen() {
  loginScreen.classList.add('hidden');
  dashboardScreen.classList.remove('hidden');
  // Load initial accounts
  loadAccounts();

  // Set up Server-Sent Events for real-time updates
  if (eventSource) {
    eventSource.close();
  }

  const token = getSessionToken();
  eventSource = new EventSource(`/api/dashboard/stream?token=${encodeURIComponent(token)}`);

  eventSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.accounts) {
        updateAccountsUI(data.accounts);
      }
    } catch (err) {
      console.error('Error parsing SSE data:', err);
    }
  };

  eventSource.onerror = (err) => {
    console.error('SSE connection error:', err);
    eventSource.close();

    // Reconnect after 5 seconds
    setTimeout(() => {
      if (sessionToken) {
        const token = getSessionToken();
        eventSource = new EventSource(`/api/dashboard/stream?token=${encodeURIComponent(token)}`);
      }
    }, 5000);
  };
}

function createAccountCard(account) {
  const card = document.createElement('div');
  card.className = 'account-card';
  card.dataset.login = account.login;

  const isOnline = account.is_online;
  const statusClass = isOnline ? 'online' : 'offline';
  const statusText = isOnline ? 'EA Online' : 'EA Offline';

  card.innerHTML = `
    <div class="account-header">
      <div class="account-info">
        <h3>${escapeHtml(account.label)}</h3>
        <div class="account-login">Account: ${account.login}${account.server ? ' • ' + escapeHtml(account.server) : ''}</div>
      </div>
      <div class="account-actions">
        <button class="delete-account-btn" data-login="${account.login}">Delete</button>
        <span class="status-badge ${statusClass}">${statusText}</span>
      </div>
    </div>
    <div class="metrics-row">
      <div class="metric">
        <div class="metric-label">Cycle Net</div>
        <div class="metric-value ${getValueClass(account.cycle_net)}">
          ${formatNumber(account.cycle_net)}
          <span class="metric-currency">${escapeHtml(account.currency)}</span>
        </div>
      </div>
      <div class="metric">
        <div class="metric-label">Realized Bank</div>
        <div class="metric-value ${getValueClass(account.realized_bank)}">
          ${formatNumber(account.realized_bank)}
          <span class="metric-currency">${escapeHtml(account.currency)}</span>
        </div>
      </div>
      <div class="metric">
        <div class="metric-label">Current Floating</div>
        <div class="metric-value ${getValueClass(account.floating_pnl)}">
          ${formatNumber(account.floating_pnl)}
          <span class="metric-currency">${escapeHtml(account.currency)}</span>
        </div>
      </div>
      <div class="metric">
        <div class="metric-label">Balance</div>
        <div class="metric-value neutral">
          ${formatNumber(account.balance)}
          <span class="metric-currency">${escapeHtml(account.currency)}</span>
        </div>
      </div>
    </div>
  `;

  // Handle delete button click
  const deleteBtn = card.querySelector('.delete-account-btn');
  if (deleteBtn) {
    deleteBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      await handleDeleteAccount(account.login, account.label);
    });
  }

  // Handle card click to show chart
  card.addEventListener('click', (e) => {
    if (e.target.closest('.delete-account-btn')) return;
    showChartModal(account.login, account.label);
  });

  return card;
}

function getValueClass(value) {
  if (value > 0) return 'positive';
  if (value < 0) return 'negative';
  return 'neutral';
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

async function handleDeleteAccount(login, label) {
  const confirmed = confirm(`Are you sure you want to delete account "${label}" (${login})?\n\nThis will remove all associated data and cannot be undone.`);

  if (!confirmed) return;

  try {
    await deleteAccount(login);
    await loadAccounts();
  } catch (err) {
    console.error('Error deleting account:', err);
    alert('Failed to delete account. Please try again.');
  }
}

function updateAccountsUI(accounts) {
  accountsGrid.innerHTML = '';

  if (accounts.length === 0) {
    accountsGrid.innerHTML = `
      <div class="empty-state">
        <h3>No Accounts Added</h3>
        <p>Click "+ Add Account" to start monitoring your MT5 accounts</p>
      </div>
    `;
    return;
  }

  accounts.forEach(account => {
    accountsGrid.appendChild(createAccountCard(account));
  });
}

async function loadAccounts() {
  try {
    const { accounts } = await fetchAccounts();
    updateAccountsUI(accounts);
  } catch (err) {
    console.error('Error loading accounts:', err);
    if (err.message.includes('Invalid or expired session')) {
      logout();
    } else {
      accountsGrid.innerHTML = `
        <div class="empty-state">
          <h3>Error Loading Accounts</h3>
          <p>${escapeHtml(err.message)}</p>
          <button class="btn btn-primary" onclick="loadAccounts()">Retry</button>
        </div>
      `;
    }
  }
}

async function showChartModal(login, label) {
  currentChartLogin = login;
  currentHours = 1;

  document.getElementById('modalTitle').textContent = `${label} (${login})`;
  chartModal.classList.remove('hidden');

  // Reset range selector
  document.querySelectorAll('#chartModal .range-btn').forEach(btn => {
    btn.classList.toggle('active', parseInt(btn.dataset.hours) === currentHours);
  });

  await updateChart();
}

function hideChartModal() {
  chartModal.classList.add('hidden');
  if (detailChart) {
    detailChart.destroy();
    detailChart = null;
  }
}

async function updateChart() {
  if (!currentChartLogin) return;

  try {
    const data = await fetchHistory(currentChartLogin, currentHours);

    const timestamps = data.snapshots.map(s => new Date(s.received_at * 1000));
    const equity = data.snapshots.map(s => s.equity);
    const netBank = data.snapshots.map(s => s.net_bank);

    if (detailChart) {
      detailChart.destroy();
    }

    const ctx = document.getElementById('detailChart').getContext('2d');
    detailChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: timestamps,
        datasets: [
          {
            label: 'Equity',
            data: equity,
            borderColor: '#60a5fa',
            backgroundColor: 'rgba(96, 165, 250, 0.1)',
            borderWidth: 2,
            tension: 0.4,
            fill: true
          },
          {
            label: 'Net Bank',
            data: netBank,
            borderColor: '#10b981',
            backgroundColor: 'rgba(16, 185, 129, 0.1)',
            borderWidth: 2,
            tension: 0.4,
            fill: true
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: {
            labels: {
              color: '#e0e0e0',
              font: { size: 12 }
            }
          },
          tooltip: {
            mode: 'index',
            intersect: false,
            backgroundColor: '#1a1a2e',
            titleColor: '#fff',
            bodyColor: '#e0e0e0',
            borderColor: '#2d2d44',
            borderWidth: 1
          }
        },
        scales: {
          x: {
            type: 'time',
            time: {
              unit: currentHours <= 1 ? 'minute' : currentHours <= 24 ? 'hour' : 'day',
              displayFormats: {
                minute: 'HH:mm',
                hour: 'HH:mm',
                day: 'MMM d'
              }
            },
            grid: {
              color: '#2d2d44'
            },
            ticks: {
              color: '#9ca3af'
            }
          },
          y: {
            grid: {
              color: '#2d2d44'
            },
            ticks: {
              color: '#9ca3af',
              callback: function(value) {
                return formatNumber(value, 0);
              }
            }
          }
        },
        interaction: {
          mode: 'nearest',
          axis: 'x',
          intersect: false
        }
      }
    });
  } catch (err) {
    console.error('Error loading chart:', err);
  }
}

function showAddAccountModal() {
  addAccountForm.reset();
  hideError(addAccountError);
  hideError(addAccountSuccess);
  apiKeyDisplay.classList.add('hidden');
  addAccountModal.classList.remove('hidden');
}

function hideAddAccountModal() {
  addAccountModal.classList.add('hidden');
}

// Event Listeners
loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  hideError(loginError);

  const password = document.getElementById('passwordInput').value;

  try {
    await login(password);
    showDashboardScreen();
  } catch (err) {
    showError(loginError, err.message || 'Login failed');
  }
});

logoutBtn.addEventListener('click', logout);
refreshBtn.addEventListener('click', loadAccounts);
addAccountBtn.addEventListener('click', showAddAccountModal);
closeModal.addEventListener('click', hideChartModal);
closeAddModal.addEventListener('click', hideAddAccountModal);

addAccountForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  hideError(addAccountError);
  hideError(addAccountSuccess);

  const login = parseInt(document.getElementById('newAccountLogin').value);
  const label = document.getElementById('newAccountLabel').value;

  try {
    const result = await addAccount(login, label);

    // Show API key
    generatedApiKey.textContent = result.api_key;
    apiKeyDisplay.classList.remove('hidden');
    addAccountForm.style.display = 'none';
    showError(addAccountSuccess, result.message);

    // Reload accounts
    loadAccounts();
  } catch (err) {
    showError(addAccountError, err.message || 'Failed to add account');
  }
});

copyApiKey.addEventListener('click', () => {
  const apiKey = generatedApiKey.textContent;
  navigator.clipboard.writeText(apiKey).then(() => {
    copyApiKey.textContent = 'Copied!';
    setTimeout(() => {
      copyApiKey.textContent = 'Copy';
    }, 2000);
  });
});

// Chart range selector
document.querySelectorAll('#chartModal .range-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('#chartModal .range-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    currentHours = parseInt(btn.dataset.hours);
    updateChart();
  });
});

// Click outside modal to close
chartModal.addEventListener('click', (e) => {
  if (e.target === chartModal) {
    hideChartModal();
  }
});

addAccountModal.addEventListener('click', (e) => {
  if (e.target === addAccountModal) {
    hideAddAccountModal();
  }
});

// Initialize
function init() {
  const token = getSessionToken();
  if (token) {
    sessionToken = token;
    showDashboardScreen();
  } else {
    showLoginScreen();
  }
}

init();
