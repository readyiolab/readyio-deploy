// PM2 process file for the Readyio VPS.
//   pm2 startOrReload deploy/ecosystem.config.cjs --update-env
// The admin panel (blogpanel.readyio.com) is static and served by Nginx, so it has no process here.
const path = require('path');

const root = path.resolve(__dirname, '..');
const nextBin = 'node_modules/next/dist/bin/next';

module.exports = {
  apps: [
    {
      name: 'readyio-api',
      cwd: path.join(root, 'Backend'),
      script: 'src/app.js',
      env: { NODE_ENV: 'production', PORT: 4000 },
      max_memory_restart: '500M',
      time: true,
    },
    {
      name: 'readyio-site',
      cwd: path.join(root, 'readyiosite'),
      script: nextBin,
      args: 'start -p 8080 -H 127.0.0.1',
      env: { NODE_ENV: 'production' },
      max_memory_restart: '700M',
      time: true,
    },
    {
      name: 'readyio-blog',
      cwd: path.join(root, 'readyiosite-blog'),
      script: nextBin,
      args: 'start -p 8081 -H 127.0.0.1',
      env: { NODE_ENV: 'production' },
      max_memory_restart: '700M',
      time: true,
    },
  ],
};
