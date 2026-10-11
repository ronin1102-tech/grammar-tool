// LWA overlay-battery fixture server (port 8083): serves the fixture page,
// receives the driver's report, and marks completion sentinels.
const http = require('http');
const fs = require('fs');
const FIXTURE = '/Users/onemoretimetrizzy/workspace/grammar-tool/tests/fixtures/form-fixture.html';
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
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(fs.readFileSync(FIXTURE));
}).listen(8083, '127.0.0.1', () => console.log('fixture up'));
