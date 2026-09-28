// Demo-mode E2E (no backend). One browser context so demo data is shared across roles.
import { chromium } from 'playwright-core';
import fs from 'node:fs';
const OUT = '/tmp/claude-0/demo-shots'; fs.mkdirSync(OUT, { recursive: true });
const BASE = process.env.BASE || 'http://localhost:5174';
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const p = await ctx.newPage(); const errors = [];
p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
p.on('console', (m) => { if (m.type() === 'error' && !/fonts|Failed to load resource/.test(m.text())) errors.push(m.text()); });
const shot = (n) => p.screenshot({ path: `${OUT}/${n}.png` });
await p.goto(BASE); await p.waitForSelector('text=Demo logins'); await shot('01_login');
await p.click('text=Promoter — Ravi'); await p.click('text=LOG IN');
await p.waitForSelector('text=SELECT STATE');
await p.click('text=Uttar Pradesh'); await p.click('text=Lucknow Central'); await p.click('text=Rahul Sharma');
await p.click('.pick-list >> text=Modern Wines'); await p.waitForSelector('text=CURRENT OUTLET'); await p.waitForTimeout(500); await shot('02_home');
await p.click('text=CHANGE OUTLET'); await p.waitForSelector('text=RECENT OUTLETS'); await p.click('.pick-list.recent >> text=Modern Wines');
for (let i = 0; i < 3; i++) {
  await p.click('.btn-start', { force: true }); await p.click('.sku >> nth=0'); await p.click('.qty >> text=2');
  await p.waitForSelector('text=HAND THE PHONE'); await p.click('.handoff'); await p.click('text=SPIN NOW', { force: true });
  await p.waitForSelector('text=PRIZE TO BE GIVEN', { timeout: 15000 }); await p.waitForTimeout(400);
  if (i === 0) { await shot('03_win'); const a = await p.textContent('.handover-prize'); await p.reload(); await p.waitForSelector('text=PRIZE TO BE GIVEN'); console.log('refresh same prize:', a === await p.textContent('.handover-prize')); }
  await p.click('text=PRIZE HANDED OVER'); await p.click('text=YES, HANDED OVER'); await p.waitForSelector('text=CURRENT OUTLET');
}
await p.click('text=CHANGE OUTLET'); await p.click('text=OUTLET NOT LISTED?');
await p.fill('.form label:nth-child(1) input', 'Sunrise Wine Point'); await p.fill('.form label:nth-child(2) input', 'Vikas Nagar');
await p.click('text=SUBMIT FOR APPROVAL'); await p.waitForSelector('text=Request sent');
await p.click('[aria-label="Log out"]'); await p.waitForSelector('text=Demo logins');
// admin on desktop size
await p.setViewportSize({ width: 1400, height: 900 });
await p.click('text=Admin'); await p.click('text=LOG IN'); await p.waitForSelector('.kpis'); await p.waitForTimeout(800); await shot('10_admin_dash');
await p.click('text=7D'); await p.waitForTimeout(800); await shot('11_admin_dash_7d');
for (const [nav, wait] of [['Reports', 'TSE Performance'], ['Transactions', 'Spin ID'], ['Promoters & Stock', 'Current outlet'], ['Flagged Activity', 'FLAGGED'],
  ['Outlet Requests', 'Sunrise'], ['Prize Pool', 'CURRENT POOL'], ['Prize Structure', 'Average Cost Per Spin'], ['Campaigns', 'RIO SPIN'],
  ['Outlets & Masters', 'Upload Outlet Master'], ['Users', 'Ravi'], ['Audit Log', 'Tamper check'], ['Data Export', 'Export data']]) {
  await p.click(`.s-side >> text=${nav}`);
  await p.waitForSelector(`text=${wait}`, { timeout: 6000 }).catch(() => errors.push(`missing "${wait}" on ${nav}`));
  await p.waitForTimeout(400); await shot('2x_' + nav.replace(/\W+/g, '_'));
}
await p.click('.s-side >> text=Outlet Requests'); await p.click('button.s-btn:has-text("Review")');
await p.selectOption('.s-modal select', { index: 1 }); await p.click('text=Approve & add to Outlet Master'); await p.waitForTimeout(600);
await p.click('.s-side >> text=Promoters & Stock'); await p.click('button.s-btn:has-text("Stock") >> nth=0'); await p.click('text=Fill one standard pool kit');
await p.click('text=Save movement'); await p.waitForTimeout(600);
await p.click('.s-side >> text=Audit Log'); await p.click('text=Verify hash chain'); await p.waitForSelector('text=Chain intact').catch(() => errors.push('audit chain not intact'));
await p.click('.s-side >> text=Users'); await p.click('text=+ Create promoter');
await p.fill('.s-modal label:has-text("Full name") input', 'Test Promoter'); await p.fill('.s-modal label:has-text("Login ID") input', '9999900000');
await p.fill('.s-modal label:has-text("PIN") input', '123456'); await p.fill('.s-modal label:has-text("Promoter ID") input', 'PRM-099');
await p.click('.s-modal >> text=Save'); await p.waitForSelector('text=Test Promoter').catch(() => errors.push('user create failed'));
await b.close();
console.log('ERRORS:', errors.length ? errors : 'none');
