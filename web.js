const compression = require('compression');
const express = require('express');
const path = require('path');
const helmet = require('helmet');
const get = require('lodash/get');
const app = express();

// Helmet helps you secure your Express apps by setting various HTTP headers
app.use(helmet({
  frameguard: {
    action: 'allow-from',
    domain: 'http://115.239.134.113:8180'
  }
}))
//app.use(express.static('./assets'));
const maxAge = 1000 * 60 * 60 * 24 * 365;
app.use(compression());
app.use(express.static('./assets'));
app.use(
  express.static('./dist', {
    // 使用强缓存
    maxAge,
    setHeaders: function(res, path) {
      if (express.static.mime.lookup(path) === 'text/html') {
        // html 文件使用协商缓存
        res.setHeader('Cache-Control', 'public, max-age=0');
      }
    },
  })
);

// 只对 index.html 使用 CSP
app.use(helmet.contentSecurityPolicy({
  directives: {
    defaultSrc: ["'self'"],
    scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'", 'www.google-analytics.com', 'stats.pusher.com', 'webapi.amap.com', 'restapi.amap.com'],
    styleSrc: ["'self'", "'unsafe-inline'", 'webapi.amap.com'],
    imgSrc: ['*', 'data:'],
    connectSrc: ['*'],
    frameSrc: ['*'],
    workerSrc: ["'self'", 'blob:'],
    mediaSrc: ["'self'", 'data:'],
  },
}))
app.get('/*', function(req, res) {
  res.sendFile(path.join(__dirname, './dist', 'index.html'));
});

