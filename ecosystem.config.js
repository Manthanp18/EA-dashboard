module.exports = {
  apps: [{
    name: 'mt5-dashboard',
    script: './server.js',
    instances: 1,
    exec_mode: 'fork',
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: 8000
    },
    error_file: './logs/error.log',
    out_file: './logs/out.log',
    time: true
  }]
};
