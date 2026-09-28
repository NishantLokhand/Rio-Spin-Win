import { chromium } from 'playwright-core';
const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const p = await b.newPage({ viewport: { width: 390, height: 844 } });
await p.goto('http://localhost:5173');
await p.fill('input[autocomplete=username]', '9876500001'); await p.fill('input[type=password]', '111111');
await p.click('text=LOG IN');
await p.click('text=Uttar Pradesh'); await p.click('text=Lucknow Central'); await p.click('text=Rahul Sharma');
await p.click('.pick-list >> text=Metro Wines');
const SEG = ['SNACK ATTACK','TREAT YOURSELF','RIO DARE','RIO SHADES','RIO PARTY JACKPOT','CRUNCH TIME','RIO SURPRISE','WIN BIG'];
for (let i = 0; i < 4; i++) {
  await p.click('.btn-start', { force: true }); await p.click('.sku >> nth=0'); await p.click('.qty >> text=1');
  await p.click('.handoff'); await p.click('text=SPIN NOW', { force: true });
  const msg = await p.waitForEvent('console', { predicate: (m) => m.text().includes('[wheel] landed'), timeout: 20000 });
  const seg = msg.text().replace('[wheel] landed ', '');
  await p.waitForSelector('text=PRIZE TO BE GIVEN');
  console.log('landed', seg, '=> prize', await p.textContent('.handover-prize'));
  await p.click('text=PRIZE HANDED OVER'); await p.click('text=YES, HANDED OVER'); await p.waitForSelector('text=CURRENT OUTLET');
}
await b.close();
