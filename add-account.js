#!/usr/bin/env node

require('dotenv').config();
const crypto = require('crypto');
const { addAccount } = require('./db');

// Generate a secure random API key
function generateApiKey() {
  return crypto.randomBytes(32).toString('hex');
}

// Main function
function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.error('Usage: node add-account.js <login> <label>');
    console.error('');
    console.error('Example: node add-account.js 12345678 "My Live Account"');
    console.error('');
    process.exit(1);
  }

  const login = parseInt(args[0], 10);
  const label = args.slice(1).join(' ');

  if (isNaN(login) || login <= 0) {
    console.error('Error: Login must be a positive integer (your MT5 account number)');
    process.exit(1);
  }

  if (!label || label.trim().length === 0) {
    console.error('Error: Label cannot be empty');
    process.exit(1);
  }

  // Generate API key
  const apiKey = generateApiKey();

  try {
    addAccount(login, apiKey, label.trim());

    console.log('');
    console.log('='.repeat(70));
    console.log('  Account created successfully!');
    console.log('='.repeat(70));
    console.log('');
    console.log('  MT5 Login:  ' + login);
    console.log('  Label:      ' + label.trim());
    console.log('');
    console.log('  API Key:    ' + apiKey);
    console.log('');
    console.log('='.repeat(70));
    console.log('');
    console.log('IMPORTANT: Save this API key now! It will not be shown again.');
    console.log('');
    console.log('To use in your MT5 EA:');
    console.log('  - Set InpApiKey to: ' + apiKey);
    console.log('');
    console.log('To login to the dashboard:');
    console.log('  - MT5 Account: ' + login);
    console.log('  - API Key: ' + apiKey);
    console.log('');
    console.log('='.repeat(70));
    console.log('');
  } catch (err) {
    if (err.code === 'SQLITE_CONSTRAINT') {
      console.error('');
      console.error('Error: Account with login ' + login + ' already exists.');
      console.error('');
      process.exit(1);
    } else {
      console.error('');
      console.error('Error creating account:', err.message);
      console.error('');
      process.exit(1);
    }
  }
}

main();
