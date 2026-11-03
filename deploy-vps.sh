#!/bin/bash

# MT5 Dashboard VPS Deployment Script
# Run this on your VPS: bash deploy-vps.sh

set -e

echo "=================================="
echo "MT5 Dashboard VPS Deployment"
echo "=================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Prompt for domain or IP
echo -e "${YELLOW}Enter your domain name (or VPS IP if no domain):${NC}"
read -p "Domain/IP: " DOMAIN

echo -e "${YELLOW}Enter your dashboard password:${NC}"
read -sp "Password: " DASHBOARD_PASS
echo ""

# Update system
echo -e "\n${GREEN}[1/10] Updating system...${NC}"
sudo apt update && sudo apt upgrade -y

# Install Node.js
echo -e "\n${GREEN}[2/10] Installing Node.js 18.x...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Install nginx and certbot
echo -e "\n${GREEN}[3/10] Installing nginx and certbot...${NC}"
sudo apt install -y nginx certbot python3-certbot-nginx

# Install PM2
echo -e "\n${GREEN}[4/10] Installing PM2...${NC}"
sudo npm install -g pm2

# Clone repository
echo -e "\n${GREEN}[5/10] Cloning repository...${NC}"
sudo mkdir -p /var/www
cd /var/www
if [ -d "EA-dashboard" ]; then
    echo "Repository exists, pulling latest changes..."
    cd EA-dashboard
    sudo git pull
else
    sudo git clone https://github.com/Manthanp18/EA-dashboard.git
    cd EA-dashboard
fi

# Set permissions
sudo chown -R $USER:$USER /var/www/EA-dashboard

# Install dependencies
echo -e "\n${GREEN}[6/10] Installing dependencies...${NC}"
npm install

# Create .env file
echo -e "\n${GREEN}[7/10] Creating .env file...${NC}"
cat > .env << EOF
PORT=8000
DB_PATH=./data/mt5.db
DASHBOARD_PASSWORD=$DASHBOARD_PASS
RATE_LIMIT_PUSH=60
RATE_LIMIT_STATE=120
EOF

# Create data directory
mkdir -p data

# Start with PM2
echo -e "\n${GREEN}[8/10] Starting application with PM2...${NC}"
pm2 delete mt5-dashboard 2>/dev/null || true
pm2 start server.js --name mt5-dashboard
pm2 save
pm2 startup | grep "sudo" | bash

# Configure nginx
echo -e "\n${GREEN}[9/10] Configuring nginx...${NC}"

# Check if domain looks like an IP
if [[ $DOMAIN =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    USE_SSL=false
else
    USE_SSL=true
fi

sudo tee /etc/nginx/sites-available/mt5-dashboard > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript;
}
EOF

sudo ln -sf /etc/nginx/sites-available/mt5-dashboard /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

# Setup SSL if domain (not IP)
if [ "$USE_SSL" = true ]; then
    echo -e "\n${GREEN}[10/10] Setting up SSL certificate...${NC}"
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --redirect
else
    echo -e "\n${YELLOW}Skipping SSL (IP address detected)${NC}"
fi

# Configure firewall
echo -e "\n${GREEN}Configuring firewall...${NC}"
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
echo "y" | sudo ufw enable

# Display results
echo ""
echo "=================================="
echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL!${NC}"
echo "=================================="
echo ""
echo "Dashboard URL:"
if [ "$USE_SSL" = true ]; then
    echo "  https://$DOMAIN"
else
    echo "  http://$DOMAIN"
fi
echo ""
echo "Dashboard Password: $DASHBOARD_PASS"
echo ""
echo "MT5 EA Whitelist URL:"
if [ "$USE_SSL" = true ]; then
    echo "  https://$DOMAIN"
else
    echo "  http://$DOMAIN"
fi
echo ""
echo "MT5 EA Settings:"
if [ "$USE_SSL" = true ]; then
    echo "  InpApiUrl = \"https://$DOMAIN/api/push\""
else
    echo "  InpApiUrl = \"http://$DOMAIN/api/push\""
fi
echo "  InpApiKey = (get from dashboard after adding account)"
echo ""
echo "Useful commands:"
echo "  pm2 logs mt5-dashboard    - View logs"
echo "  pm2 restart mt5-dashboard - Restart app"
echo "  cd /var/www/EA-dashboard && git pull && pm2 restart mt5-dashboard - Update"
echo ""
echo "=================================="
