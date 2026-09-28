// Browser E2E: promoter journey + staff dashboards, with screenshots
import { chromium } from 'playwright-core';
const EXE = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const OUT = process.argv[2] || '/tmp/claude-0/shots';
import fs from 'node:fs'; fs.mkdirSync(OUT, { recursive: true });
const BASE = 'http://localhost:5173';
const browser = await chromium.launch({ executablePath: EXE, headless: true });
const errors = [];
const shot = async (page, name) => page.screenshot({ path: `${OUT}/${name}.png` });

// ---------------- PROMOTER (Android-size viewport) ----------------
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
const p = await ctx.newPage();
p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
await p.goto(BASE);
await shot(p, '01_login');
await p.fill('input[autocomplete=username]', '9876500001');
await p.fill('input[type=password]', '111111');
await p.click('text=LOG IN');
await p.waitForSelector('text=SELECT STATE');
await shot(p, '02_select_state');
await p.click('text=Uttar Pradesh');
await p.click('text=Lucknow Central');
await p.click('text=Rahul Sharma');
await p.waitForSelector('text=SELECT OUTLET');
await shot(p, '03_select_outlet');
await p.click('.pick-list >> text=Modern Wines');
await p.waitForSelector('text=CURRENT OUTLET');
await p.waitForTimeout(800);
await shot(p, '04_home');
await p.screenshot({ path: `${OUT}/04b_home_full.png`, fullPage: true });

// Change outlet: only mapped outlets of Rahul Sharma, with recent
await p.click('text=CHANGE OUTLET');
await p.waitForSelector('text=RECENT OUTLETS');
await shot(p, '05_change_outlet');
await p.fill('.search', 'gomti');
await p.waitForTimeout(200);
await shot(p, '05b_search');
await p.click('.pick-list >> text=Royal Wine Shop');
await p.waitForSelector('text=Royal Wine Shop');

// 3 transactions
for (let i = 0; i < 3; i++) {
  await p.click('.btn-start', { force: true });
  await p.waitForSelector('text=WHICH RIO?');
  if (i === 0) await shot(p, '06_sku');
  await p.click('.sku >> nth=0');
  if (i === 0) await shot(p, '07_qty');
  await p.click('.qty >> text=2');
  await p.waitForSelector('text=HAND THE PHONE TO THE CUSTOMER');
  if (i === 0) await shot(p, '08_handoff');
  await p.click('.handoff');
  if (i === 0) await shot(p, '09_spin_ready');
  await p.click('text=SPIN NOW', { force: true });
  await p.waitForTimeout(1500);
  if (i === 0) await shot(p, '10_spinning');
  await p.waitForSelector('text=PRIZE TO BE GIVEN', { timeout: 15000 });
  await p.waitForTimeout(600);
  await shot(p, `11_win_${i}`);
  // refresh must NOT re-draw: reload and confirm same prize shown
  if (i === 0) {
    const before = await p.textContent('.handover-prize');
    await p.reload();
    await p.waitForSelector('text=PRIZE TO BE GIVEN', { timeout: 10000 });
    const after = await p.textContent('.handover-prize');
    console.log('refresh resume same prize:', before === after, before);
  }
  await p.click('text=PRIZE HANDED OVER');
  await p.click('text=YES, HANDED OVER');
  await p.waitForSelector('text=CURRENT OUTLET');
}
await p.waitForTimeout(800);
await shot(p, '12_home_after');

// Outlet not listed
await p.click('text=CHANGE OUTLET');
await p.click('text=OUTLET NOT LISTED?');
await p.fill('.form label:nth-child(1) input', 'Sunrise Wine Point');
await p.fill('.form label:nth-child(2) input', 'Vikas Nagar');
await shot(p, '13_not_listed');
await p.click('text=SUBMIT FOR APPROVAL');
await p.waitForSelector('text=Request sent');
await ctx.close();

// ---------------- ADMIN (desktop) ----------------
const actx = await browser.newContext({ viewport: { width: 1400, height: 900 } });
const a = await actx.newPage();
a.on('pageerror', (e) => errors.push('admin pageerror: ' + e.message));
a.on('console', (m) => { if (m.type() === 'error') errors.push('admin console: ' + m.text()); });
await a.goto(BASE);
await a.fill('input[autocomplete=username]', 'admin');
await a.fill('input[type=password]', 'admin123');
await a.click('text=LOG IN');
await a.waitForSelector('.kpis');
await a.waitForTimeout(1200);
await shot(a, '20_admin_dashboard');
await a.screenshot({ path: `${OUT}/20b_admin_dashboard_full.png`, fullPage: true });
for (const [nav, name, wait] of [['Reports', '21_reports_tse', 'TSE Performance'], ['Transactions', '22_transactions', 'Spin ID'],
  ['Promoters & Stock', '23_promoters', 'Current outlet'], ['Flagged Activity', '24_flags', 'FLAGGED'], ['Outlet Requests', '25_requests', 'Sunrise'],
  ['Prize Pool', '26_pool', 'CURRENT POOL'], ['Prize Structure', '27_prize_structure', 'Average Cost Per Spin'], ['Campaigns', '28_campaigns', 'RIO SPIN'],
  ['Outlets & Masters', '29_masters', 'Upload Outlet Master'], ['Users', '30_users', 'Ravi'], ['Audit Log', '31_audit', 'Tamper check'], ['Data Export', '32_exports', 'Export data']]) {
  await a.click(`.s-side >> text=${nav}`);
  await a.waitForSelector(`text=${wait}`, { timeout: 8000 }).catch(() => errors.push('missing text on ' + nav + ': ' + wait));
  await a.waitForTimeout(700);
  await shot(a, name);
}
// prize structure warning
await a.click('.s-side >> text=Prize Structure');
await a.waitForSelector('table.cfg');
const qtyInputs = await a.$$('table.cfg tbody tr td:nth-child(3) input');
await qtyInputs[4].fill('3'); await qtyInputs[0].fill('150');
await a.waitForTimeout(200);
await shot(a, '33_cost_warning');
// approve the outlet request
await a.click('.s-side >> text=Outlet Requests');
await a.click('button.s-btn:has-text("Review")');
await a.selectOption('.s-modal select', { index: 1 });
await a.click('text=Approve & add to Outlet Master');
await a.waitForTimeout(800);
// verify audit chain button
await a.click('.s-side >> text=Audit Log');
await a.click('text=Verify hash chain');
await a.waitForSelector('text=Chain intact');
await shot(a, '34_audit_verified');
await actx.close();

// ---------------- SUPERVISOR (mobile) ----------------
const sctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const s = await sctx.newPage();
await s.goto(BASE);
await s.fill('input[autocomplete=username]', 'sup.lucknow');
await s.fill('input[type=password]', '222222');
await s.click('text=LOG IN');
await s.waitForSelector('.kpis');
await s.waitForTimeout(1000);
await shot(s, '40_supervisor_mobile');
await sctx.close();

await browser.close();
console.log('ERRORS:', errors.length ? errors : 'none');
