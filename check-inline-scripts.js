// Parse-check every inline <script> block in web/index.html (the v17 login-page
// incident guard). Exits 1 if any block fails to parse.
const fs = require('fs');
const path = require('path');
const html = fs.readFileSync(path.join(__dirname, 'web/index.html'), 'utf8');
const re = /<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/gi;
let m, i = 0, bad = 0;
while ((m = re.exec(html))) {
  i++;
  try { new Function(m[1]); }
  catch (e) { bad++; console.log('script block ' + i + ' FAIL: ' + e.message); }
}
console.log(i + ' inline script blocks, ' + bad + ' failed');
process.exit(bad ? 1 : 0);
