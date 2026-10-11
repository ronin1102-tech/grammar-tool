// LWA forms-battery fixture server (port 8083): serves the fixture page and
// marks the sentinel when the in-page driver finishes its scenario.
const http = require('http');
const fs = require('fs');
const FIXTURE = '/Users/onemoretimetrizzy/workspace/grammar-tool/.scratch/fixture/form-fixture.html';
const SENTINEL = '/tmp/lwa-forms-done';
http.createServer((req, res) => {
  if (req.url.startsWith('/battery-done')) {
    fs.writeFileSync(SENTINEL, String(Date.now()));
    res.writeHead(204); res.end(); return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(fs.readFileSync(FIXTURE));
}).listen(8083, '127.0.0.1', () => console.log('fixture up'));
