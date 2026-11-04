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
let miniCharts = new Map(); // Store mini chart instances
let currentPage = 1;
const accountsPerPage = 8;

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
  const token = sessionStorage.getItem(SESSION_TOKEN_KEY);
  if (token) {
    console.log('✅ Session token found');
  } else {
    console.log('❌ No session token found');
  }
  return token;
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

async function createAccountCard(account) {
  const card = document.createElement('div');
  card.className = 'account-card';
  card.dataset.login = account.login;

  const isOnline = account.is_online;
  const statusClass = isOnline ? 'online' : 'offline';
  const statusText = isOnline ? 'EA Online' : 'EA Offline';

  const canvasId = `miniChart_${account.login}`;

  // EA status badge
  const eaStatusClass = account.ea_status === 'RUNNING' ? 'online' :
                        account.ea_status === 'PAUSED' ? 'paused' : 'offline';
  const eaStatusText = account.ea_status || statusText;

  // Build EA info line
  const eaInfo = account.ea_name ?
    `${escapeHtml(account.ea_name)}${account.ea_version ? ' v' + escapeHtml(account.ea_version) : ''}` : null;
  const symbol = account.ea_symbol ? ` • ${escapeHtml(account.ea_symbol)}` : '';
  const mode = account.source_mode ? ` • ${escapeHtml(account.source_mode).toUpperCase()}` : '';

  card.innerHTML = `
    <div class="account-header">
      <div class="account-info">
        <div class="account-title-row">
          <h3>${escapeHtml(account.label)}</h3>
          <span class="status-indicator ${eaStatusClass}"></span>
        </div>
        <div class="account-meta">
          <span class="account-number">${account.login}</span>
          ${account.server ? `<span class="meta-divider">•</span><span class="meta-item">${escapeHtml(account.server)}</span>` : ''}
          ${symbol ? `<span class="meta-divider">•</span><span class="meta-item">${escapeHtml(account.ea_symbol)}</span>` : ''}
          ${mode ? `<span class="meta-divider">•</span><span class="meta-badge">${escapeHtml(account.source_mode).toUpperCase()}</span>` : ''}
        </div>
        ${eaInfo ? `<div class="ea-info">${eaInfo}</div>` : ''}
      </div>
    </div>
    <div class="metrics-row">
      <div class="metric">
        <div class="metric-label">Today's P&L</div>
        <div class="metric-value ${getValueClass(account.today_pnl || 0)}">
          ${formatNumber(account.today_pnl || 0)}
          <span class="metric-currency">${escapeHtml(account.currency)}</span>
        </div>
      </div>
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
    <div class="card-footer">
      <button class="delete-account-btn" data-login="${account.login}" title="Delete account">
        <svg width="18" height="18" viewBox="0 0 16 16" fill="none">
          <path d="M2 4h12M5.333 4V2.667a1.333 1.333 0 0 1 1.334-1.334h2.666a1.333 1.333 0 0 1 1.334 1.334V4m2 0v9.333a1.333 1.333 0 0 1-1.334 1.334H4.667a1.333 1.333 0 0 1-1.334-1.334V4h9.334Z" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </button>
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

  // Create mini chart after card is added to DOM
  setTimeout(async () => {
    await createMiniChart(account.login, canvasId);
  }, 100);

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

// Create mini chart for account card
async function createMiniChart(login, canvasId) {
  try {
    // Destroy existing chart if any
    if (miniCharts.has(login)) {
      miniCharts.get(login).destroy();
    }

    const canvas = document.getElementById(canvasId);
    if (!canvas) return;

    // Fetch last 1 hour of data for mini chart
    const data = await fetchHistory(login, 1);

    if (!data.snapshots || data.snapshots.length === 0) {
      return; // No data yet
    }

    const timestamps = data.snapshots.map(s => new Date(s.received_at * 1000));
    const equity = data.snapshots.map(s => s.equity);

    const ctx = canvas.getContext('2d');
    const chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: timestamps,
        datasets: [{
          data: equity,
          borderColor: '#10b981',
          backgroundColor: 'rgba(16, 185, 129, 0.1)',
          borderWidth: 2,
          tension: 0.4,
          fill: true,
          pointRadius: 0,
          pointHoverRadius: 0
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: { enabled: false }
        },
        scales: {
          x: {
            display: false
          },
          y: {
            display: false
          }
        },
        interaction: {
          mode: 'nearest',
          axis: 'x',
          intersect: false
        }
      }
    });

    miniCharts.set(login, chart);
  } catch (err) {
    console.error(`Error creating mini chart for ${login}:`, err);
  }
}

async function updateAccountsUI(accounts) {
  // Clear old mini charts
  miniCharts.forEach(chart => chart.destroy());
  miniCharts.clear();

  accountsGrid.innerHTML = '';

  if (accounts.length === 0) {
    accountsGrid.innerHTML = `
      <div class="empty-state">
        <h3>No Accounts Added</h3>
        <p>Click "+ Add Account" to start monitoring your MT5 accounts</p>
      </div>
    `;
    updatePagination(0);
    return;
  }

  // Pagination logic
  const totalPages = Math.ceil(accounts.length / accountsPerPage);
  const startIndex = (currentPage - 1) * accountsPerPage;
  const endIndex = startIndex + accountsPerPage;
  const paginatedAccounts = accounts.slice(startIndex, endIndex);

  // Create cards for paginated accounts
  for (const account of paginatedAccounts) {
    const card = await createAccountCard(account);
    accountsGrid.appendChild(card);
  }

  updatePagination(accounts.length);
}

function updatePagination(totalAccounts) {
  let paginationEl = document.getElementById('pagination');

  if (!paginationEl) {
    paginationEl = document.createElement('div');
    paginationEl.id = 'pagination';
    paginationEl.className = 'pagination';
    accountsGrid.parentNode.appendChild(paginationEl);
  }

  if (totalAccounts === 0) {
    paginationEl.classList.add('hidden');
    return;
  }

  paginationEl.classList.remove('hidden');

  const totalPages = Math.ceil(totalAccounts / accountsPerPage);
  const startIndex = (currentPage - 1) * accountsPerPage + 1;
  const endIndex = Math.min(startIndex + accountsPerPage - 1, totalAccounts);

  paginationEl.innerHTML = `
    <div class="pagination-info">
      Showing ${startIndex} - ${endIndex} of ${totalAccounts} account${totalAccounts !== 1 ? 's' : ''}
    </div>
    <div class="pagination-controls">
      <button class="pagination-btn" id="prevPage" ${currentPage === 1 ? 'disabled' : ''}>‹</button>
      ${Array.from({ length: totalPages }, (_, i) => i + 1)
        .map(page => `
          <button class="pagination-btn ${page === currentPage ? 'active' : ''}" data-page="${page}">
            ${page}
          </button>
        `).join('')}
      <button class="pagination-btn" id="nextPage" ${currentPage === totalPages ? 'disabled' : ''}>›</button>
    </div>
  `;

  // Add event listeners
  document.getElementById('prevPage')?.addEventListener('click', () => {
    if (currentPage > 1) {
      currentPage--;
      loadAccounts();
    }
  });

  document.getElementById('nextPage')?.addEventListener('click', () => {
    if (currentPage < totalPages) {
      currentPage++;
      loadAccounts();
    }
  });

  document.querySelectorAll('.pagination-btn[data-page]').forEach(btn => {
    btn.addEventListener('click', () => {
      currentPage = parseInt(btn.dataset.page);
      loadAccounts();
    });
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
    const cycleNet = data.snapshots.map(s => s.cycle_net);
    const realizedBank = data.snapshots.map(s => s.realized_bank);

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
            borderColor: '#3b82f6',
            backgroundColor: 'rgba(59, 130, 246, 0.1)',
            borderWidth: 3,
            tension: 0.4,
            fill: true
          },
          {
            label: 'Cycle Net',
            data: cycleNet,
            borderColor: '#10b981',
            backgroundColor: 'rgba(16, 185, 129, 0.1)',
            borderWidth: 3,
            tension: 0.4,
            fill: true
          },
          {
            label: 'Realized Bank',
            data: realizedBank,
            borderColor: '#8b5cf6',
            backgroundColor: 'rgba(139, 92, 246, 0.1)',
            borderWidth: 3,
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
              color: '#cbd5e1',
              font: { size: 13, weight: '600' },
              padding: 16,
              usePointStyle: true
            }
          },
          tooltip: {
            mode: 'index',
            intersect: false,
            backgroundColor: '#141824',
            titleColor: '#f1f5f9',
            bodyColor: '#cbd5e1',
            borderColor: '#334155',
            borderWidth: 2,
            padding: 12,
            titleFont: { size: 13, weight: 'bold' },
            bodyFont: { size: 12 },
            cornerRadius: 8
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
              color: '#1e293b',
              drawBorder: false
            },
            ticks: {
              color: '#94a3b8',
              font: { size: 11 }
            }
          },
          y: {
            grid: {
              color: '#1e293b',
              drawBorder: false
            },
            ticks: {
              color: '#94a3b8',
              font: { size: 11 },
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
