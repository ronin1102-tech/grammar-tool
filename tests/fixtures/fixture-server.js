// LWA fixture server v4 (port 8083): multi-route. / -> forms fixture,
// /gmail -> gmail fixture, /dict -> dict live-overlay fixture (J12).
// Driver report + sentinels as before. Serves from its own directory.
const http = require('http');
const fs = require('fs');
const DIR = __dirname;
http.createServer((req, res) => {
  if (req.url.startsWith('/battery-done')) {
    fs.writeFileSync('/tmp/lwa-forms-done', String(Date.now()));
    res.writeHead(204); res.end(); return;
  }
  if (req.url.startsWith('/driver-report')) {
    let b = '';
    req.on('data', c => b += c);
    req.on('end', () => { fs.writeFileSync('/tmp/lwa-driver-report.json', b); res.writeHead(204); res.end(); });
    return;
  }
  let file = DIR + '/form-fixture.html';
  if (req.url.startsWith('/gmail')) file = DIR + '/gmail-fixture.html';
  if (req.url.startsWith('/dict')) file = DIR + '/dict-fixture.html';
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(fs.readFileSync(file));
}).listen(8083, '127.0.0.1', () => console.log('fixture up (v4)'));
