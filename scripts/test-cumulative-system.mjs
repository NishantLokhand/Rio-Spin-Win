// Automated verification for Controlled Cumulative Random Allocation System
// Node.js polyfill — localStorage is browser-only, not available in Node
globalThis.localStorage = {
  _store: {},
  getItem(k) { return this._store[k] ?? null; },
  setItem(k, v) { this._store[k] = v; },
  removeItem(k) { delete this._store[k]; },
};
// Note: Node v18+ has globalThis.crypto built-in — no import needed

import { seedDb, U, CAMPAIGN } from '../web/src/lib/demo/seed.js';
import { Engine } from '../web/src/lib/demo/engine.js';

function createEngine() {
  // Bypass localStorage: create engine then override db with a fresh seed
  const eng = new Engine();
  eng.db = seedDb();
  // Keep a clean ledger so each test can assert exact campaign spin totals.
  return eng;
}

function assert(condition, message) {
  if (!condition) {
    console.error('FAIL:', message);
    throw new Error(message);
  }
}

async function runTests() {
  console.log('=== STARTING RIO SPIN & WIN CUMULATIVE ALLOCATION TESTS ===\n');

  // -------------------------------------------------------------
  // Test 1: Expected Giveaway Cost dynamically calculates to ₹10.00
  // -------------------------------------------------------------
  console.log('Test 1: Dynamic cost calculation from percentages');
  const engine = createEngine();
  engine.uid = U.admin;
  const statusBefore = engine.pool_status({ p_campaign: CAMPAIGN });
  const cfg = statusBefore.configs[0];
  console.log('Active Config Expected Avg Cost:', cfg.avg_cost);
  assert(Math.abs(cfg.avg_cost - 10.00) < 0.01, `Expected cost must be 10.00, got ${cfg.avg_cost}`);
  console.log('✓ PASS: Dynamic expected cost calculates to ₹10.00/spin\n');

  console.log('Test 1b: Admin percentage edits recalculate expected economics');
  const changed = createEngine();
  changed.uid = U.admin;
  const originalItems = changed.db.prize_config_items.filter((item) => item.config_id === changed.db.prize_configs[0].id);
  const revisedItems = originalItems.map((item) => ({
    prize_id: item.prize_id,
    percentage: item.prize_id === changed.db.prizes.find((p) => p.code === 'SNACK5').id ? 75
      : item.prize_id === changed.db.prizes.find((p) => p.code === 'SNACK10').id ? 18 : item.percentage,
    quantity: item.quantity,
    unit_cost: item.unit_cost,
  }));
  const revised = changed.save_prize_config({ p_campaign: CAMPAIGN, p_state: null, p_pool_size: 200,
    p_items: revisedItems, p_override: true, p_notes: 'percentage update test' });
  assert(Math.abs(revised.avg_cost - 10.05) < 0.01, `Changed shares should recalculate cost to ₹10.05 (got ₹${revised.avg_cost})`);
  console.log('✓ PASS: Cost is recalculated from the changed percentages and costs\n');

  // -------------------------------------------------------------
  // Test 2: Promoter dashboard omits prize_cost & avg_cost
  // -------------------------------------------------------------
  console.log('Test 2: Promoter dashboard privacy check');
  engine.uid = U.p1;
  const pHome = engine.get_promoter_home();
  console.log('Promoter today metrics:', Object.keys(pHome.today));
  assert(pHome.today.prize_cost === undefined, 'prize_cost must NOT be exposed to promoter');
  assert(pHome.today.avg_cost === undefined, 'avg_cost must NOT be exposed to promoter');
  assert(pHome.today.sales !== undefined, 'sales must be present');
  assert(pHome.today.spins !== undefined, 'spins must be present');
  assert(pHome.today.prizes_given !== undefined, 'prizes_given must be present');
  assert(pHome.today.units !== undefined, 'units must be present');
  console.log('✓ PASS: Promoter dashboard has clean 4-card operational metrics only\n');

  // -------------------------------------------------------------
  // Test 3: Idempotency (replay attack & duplicate request)
  // -------------------------------------------------------------
  console.log('Test 3: Idempotency & duplicate protection');
  engine.uid = U.p1;
  const out1 = engine.db.outlets[0].id;
  const prod1 = engine.db.products[0].id;
  engine.set_work_context({ p_outlet_id: out1 });
  const saleId = 's0000000-0000-0000-0000-000000000001';
  engine.record_sale({ p_sale_id: saleId, p_outlet_id: out1, p_product_id: prod1, p_quantity: 1 });

  const spin1 = engine.play_spin({ p_sale_id: saleId, p_spin_no: 1 });
  const spin1Replay = engine.play_spin({ p_sale_id: saleId, p_spin_no: 1 });

  assert(spin1.spin_id === spin1Replay.spin_id, 'Spin ID must match on replay');
  assert(spin1.prize.id === spin1Replay.prize.id, 'Prize must match on replay');
  assert(spin1Replay.replayed === true, 'Replayed flag must be true');
  engine.confirm_handover({ p_spin_id: spin1.spin_id });
  console.log('✓ PASS: Spin draw is idempotent and safe against duplicate requests\n');

  // -------------------------------------------------------------
  // Test 4: Physical Inventory Constraint (Out of stock handling)
  // -------------------------------------------------------------
  console.log('Test 4: Inventory constraint (Speaker = 0 stock)');
  const engNoSpeaker = createEngine();
  for (const inv of engNoSpeaker.db.promoter_inventory) if (inv.promoter_id === U.p1) inv.on_hand = 1000;
  engNoSpeaker.uid = U.p1;
  engNoSpeaker.set_work_context({ p_outlet_id: out1 });

  // Set speaker stock to 0 for promoter 1
  const speakerId = engNoSpeaker.db.prizes.find((p) => p.code === 'SPEAKER').id;
  const shadesId = engNoSpeaker.db.prizes.find((p) => p.code === 'SHADES').id;
  const p1SpeakerInv = engNoSpeaker.db.promoter_inventory.find((i) => i.promoter_id === U.p1 && i.prize_id === speakerId);
  const p1ShadesInv = engNoSpeaker.db.promoter_inventory.find((i) => i.promoter_id === U.p1 && i.prize_id === shadesId);
  p1SpeakerInv.on_hand = 0;
  p1ShadesInv.on_hand = 0;

  console.log('Test 4a: Strict shortage policy pauses a sale before a prize is revealed');
  engNoSpeaker.db.campaigns.find((c) => c.id === CAMPAIGN).oos_mode = 'block';
  engNoSpeaker.uid = U.p1;
  engNoSpeaker.set_work_context({ p_outlet_id: out1 });
  let pausedForShortage = false;
  try {
    engNoSpeaker.record_sale({ p_sale_id: 's0000000-0000-0000-0000-000000000009', p_outlet_id: out1, p_product_id: prod1, p_quantity: 1 });
  } catch (error) { pausedForShortage = error.code === 'OUT_OF_STOCK'; }
  assert(pausedForShortage, 'Strict shortage policy must pause before recording a spin sale');
  engNoSpeaker.db.campaigns.find((c) => c.id === CAMPAIGN).oos_mode = 'defer';
  console.log('✓ PASS: Strict shortage mode blocks spins while configured stock is unavailable\n');

  // Perform 250 spins where speaker is out of stock
  for (let i = 0; i < 250; i++) {
    const sId = `s0000000-0000-0000-0000-${String(i + 10).padStart(12, '0')}`;
    engNoSpeaker.record_sale({ p_sale_id: sId, p_outlet_id: out1, p_product_id: prod1, p_quantity: 1 });
    const sp = engNoSpeaker.play_spin({ p_sale_id: sId, p_spin_no: 1 });
    assert(sp.prize.code !== 'SPEAKER' && sp.prize.code !== 'SHADES', 'A prize must NEVER be awarded when its stock is 0');
    engNoSpeaker.confirm_handover({ p_spin_id: sp.spin_id });
  }

  // Check cumulative status
  engNoSpeaker.uid = U.admin;
  const statusNoSpeaker = engNoSpeaker.pool_status({ p_campaign: CAMPAIGN });
  const speakerDist = statusNoSpeaker.distribution.items.find((it) => it.short_name.toLowerCase().includes('speaker'));
  console.log('Speaker when 0 stock:', {
    target_count: speakerDist.target_count,
    actual_count: speakerDist.actual_count,
    variance: speakerDist.variance_pct,
  });
  assert(speakerDist.actual_count === 0, 'Speaker actual count must be 0');
  assert(speakerDist.target_count > 1.0, 'Speaker target count must have accumulated');
  const shadesDist = statusNoSpeaker.distribution.items.find((it) => it.short_name === 'Rio Shades');
  assert(shadesDist.actual_count === 0 && shadesDist.target_count > 0, 'Sunglasses shortage must be recorded as a continuing target deficit');
  console.log('✓ PASS: 0-stock prizes are never awarded and accumulate deficit\n');

  // Replenish speaker stock and verify catch-up
  console.log('Test 4b: Deficit recovery after replenishment');
  p1SpeakerInv.on_hand = 5;
  p1ShadesInv.on_hand = 5;
  engNoSpeaker.uid = U.p1;
  let wonSpeaker = false;
  for (let i = 250; i < 350; i++) {
    const sId = `s0000000-0000-0000-0000-${String(i + 10).padStart(12, '0')}`;
    engNoSpeaker.record_sale({ p_sale_id: sId, p_outlet_id: out1, p_product_id: prod1, p_quantity: 1 });
    const sp = engNoSpeaker.play_spin({ p_sale_id: sId, p_spin_no: 1 });
    if (sp.prize.code === 'SPEAKER') wonSpeaker = true;
    engNoSpeaker.confirm_handover({ p_spin_id: sp.spin_id });
  }
  assert(wonSpeaker, 'Speaker should be awarded following replenishment due to accumulated deficit');
  console.log('✓ PASS: Replenished high-deficit prize was awarded as expected\n');

  // -------------------------------------------------------------
  // Test 5: Cumulative Allocation Accuracy beyond the old 200-spin boundary
  // -------------------------------------------------------------
  console.log('Test 5: Continuous 500-spin cumulative distribution accuracy');
  const eng500 = createEngine();

  // Give ample inventory to promoter 1
  for (const inv of eng500.db.promoter_inventory) {
    if (inv.promoter_id === U.p1) inv.on_hand = 10000;
  }

  eng500.uid = U.p1;
  eng500.set_work_context({ p_outlet_id: out1 });

  const milestones = new Set([100, 200, 250, 500, 1000, 5000]);
  const milestoneTotals = {};
  for (let i = 1; i <= 5000; i++) {
    const sId = `s500-0000-0000-0000-${String(i).padStart(12, '0')}`;
    eng500.record_sale({ p_sale_id: sId, p_outlet_id: out1, p_product_id: prod1, p_quantity: 1 });
    const sp = eng500.play_spin({ p_sale_id: sId, p_spin_no: 1 });
    eng500.confirm_handover({ p_spin_id: sp.spin_id });
    if (milestones.has(i)) {
      eng500.uid = U.admin;
      milestoneTotals[i] = eng500.pool_status({ p_campaign: CAMPAIGN }).distribution;
      eng500.uid = U.p1;
    }
  }

  eng500.uid = U.admin;
  const rep500 = milestoneTotals[500];
  console.log('\n--- 500 SPINS CAMPAIGN DISTRIBUTION ---');
  console.table(rep500.items.map((i) => ({
    Prize: i.name,
    'Target %': i.target_pct + '%',
    'Target Count': i.target_count,
    'Actual Won': i.actual_count,
    'Actual Share': i.actual_pct + '%',
    'Variance %': (i.variance_pct > 0 ? '+' : '') + i.variance_pct + '%',
  })));

  const snack5 = rep500.items.find((i) => i.unit_cost === 5);
  const snack10 = rep500.items.find((i) => i.unit_cost === 10 && i.target_pct === 17);
  const dare = rep500.items.find((i) => i.target_pct === 5);
  const shades = rep500.items.find((i) => i.target_pct === 1.5);
  const speaker = rep500.items.find((i) => i.target_pct === 0.5);

  const totalWon = rep500.items.reduce((sum, i) => sum + i.actual_count, 0);
  assert(totalWon === 500, `Total won prizes (${totalWon}) must equal 500 spins`);

  // Verify shares are within tight bounds around target
  assert(Math.abs(snack5.actual_pct - 76.0) <= 2.5, `₹5 snack share close to 76% (got ${snack5.actual_pct}%)`);
  assert(Math.abs(snack10.actual_pct - 17.0) <= 2.0, `₹10 snack share close to 17% (got ${snack10.actual_pct}%)`);
  assert(Math.abs(dare.actual_pct - 5.0) <= 1.5, `Rio Dare share close to 5% (got ${dare.actual_pct}%)`);
  assert(shades.actual_count >= 5 && shades.actual_count <= 11, `Shades count close to 7.5 (got ${shades.actual_count})`);
  assert(speaker.actual_count >= 1 && speaker.actual_count <= 5, `Speaker count close to 2.5 (got ${speaker.actual_count})`);
  console.log(`✓ PASS: 500 spins closely matched mathematical distribution! Total cost: ₹${rep500.giveaway_cost} (Avg: ₹${rep500.avg_giveaway_cost})\n`);
  for (const n of milestones) {
    const d = milestoneTotals[n];
    const won = d.items.reduce((sum, i) => sum + i.actual_count, 0);
    assert(d.total_spins === n && won === n, `${n} spin milestone must account for exactly ${n} prizes (spins=${d.total_spins}, prizes=${won})`);
    assert(d.items.every((i) => Math.abs(i.actual_pct - i.target_pct) <= 2), `${n} spin distribution must stay within 2 percentage points per prize`);
    console.log(`✓ PASS: ${n} spins continue with one recorded prize per spin`);
  }
  const prizeReport = eng500.prize_distribution_report({ p_filters: { campaign_id: CAMPAIGN } });
  assert(prizeReport.reduce((sum, row) => sum + row.target_pct, 0) === 100, 'Filtered prize report target shares must total 100%');
  assert(prizeReport.every((row) => row.variance_pct === Number((row.pct - row.target_pct).toFixed(2))), 'Filtered prize report must calculate actual variance from target share');
  console.log('✓ PASS: Filtered prize report includes actual share, target share, and variance');

  // -------------------------------------------------------------
  // Test 6: Multi-promoter concurrency across outlets
  // -------------------------------------------------------------
  console.log('Test 6: Multi-promoter shared campaign allocation (interleaved demo requests)');
  const engMulti = createEngine();

  // Ample inventory for p1, p2, p3
  for (const inv of engMulti.db.promoter_inventory) inv.on_hand = 1000;

  const promoters = [U.p1, U.p2, U.p3];
  const outlets = engMulti.db.outlets.slice(0, 3).map((o) => o.id);

  // Set work contexts
  for (let p = 0; p < promoters.length; p++) {
    engMulti.uid = promoters[p];
    engMulti.set_work_context({ p_outlet_id: outlets[p] });
  }

  // Interleave spins among promoters
  let spinCounter = 0;
  for (let round = 1; round <= 100; round++) {
    for (let p = 0; p < promoters.length; p++) {
      spinCounter++;
      engMulti.uid = promoters[p];
      const sId = `multi-${round}-${p}-${spinCounter}`;
      engMulti.record_sale({ p_sale_id: sId, p_outlet_id: outlets[p], p_product_id: prod1, p_quantity: 1 });
      const sp = engMulti.play_spin({ p_sale_id: sId, p_spin_no: 1 });
      engMulti.confirm_handover({ p_spin_id: sp.spin_id });
    }
  }

  engMulti.uid = U.admin;
  const repMulti = engMulti.pool_status({ p_campaign: CAMPAIGN });
  console.log(`Completed ${spinCounter} concurrent interleaved spins across 3 promoters.`);
  assert(repMulti.distribution.total_spins === 300, `Campaign total spins must be 300 (got ${repMulti.distribution.total_spins})`);
  assert(engMulti.db.campaign_allocations.length === 1 && engMulti.db.campaign_allocations[0].total_spins === 300,
    'Multiple promoters must update one campaign-wide allocation ledger');
  console.log('✓ PASS: Concurrency across promoters maintained coherent campaign ledger\n');

  console.log('====================================================');
  console.log('ALL VERIFICATION AND REGRESSION TEST CASES PASSED!');
  console.log('====================================================\n');
}

runTests().catch((e) => {
  console.error('Test suite failed:', e);
  process.exit(1);
});
