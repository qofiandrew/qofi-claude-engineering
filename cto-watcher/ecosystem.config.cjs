// ecosystem.config.js — pm2 process definition for the cto-watcher relay.
//
//   pm2 start ecosystem.config.js
//   pm2 logs cto-watcher
//   pm2 save            # persist across reboots (then `pm2 startup` once)
//
// pm2 reads .env itself? No — the watcher loads .env via dotenv at startup, so
// the token stays in cto-watcher/.env (gitignored), not here.
module.exports = {
  apps: [
    {
      name: 'cto-watcher',
      script: './index.js',
      cwd: __dirname,
      instances: 1,          // a relay MUST be a singleton — two instances would double-shuttle
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 50,
      restart_delay: 5000,   // back off 5s between restarts so a crash-loop doesn't hammer the gateway
      time: true,            // prefix log lines with timestamps
      env: {
        NODE_ENV: 'production',
      },
    },
  ],
};
