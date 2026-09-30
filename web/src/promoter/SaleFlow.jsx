import React, { useMemo, useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { uuid, deviceRef } from '../lib/store.js';
import { sound } from '../lib/sound.js';

const LABELS = { invoice_no: 'Invoice number', receipt_no: 'Receipt number', qr_code: 'QR code', barcode: 'Product barcode' };

// Add any mix of SKUs to one bill. Each unit in the basket earns one sequential spin.
export default function SaleFlow({ ctx, products, online, onRecorded, onBack, onPending, say }) {
  const [basket, setBasket] = useState([]);
  const [stage, setStage] = useState('basket');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [saleId] = useState(() => uuid());
  const rules = ctx.campaign?.validation_rules || {};
  const required = Object.entries(rules).filter(([, v]) => v === 'required' || v === 'optional').map(([k, v]) => ({ k, v }));
  const [validation, setValidation] = useState({});
  const [customerName, setCustomerName] = useState('');
  const [customerPhone, setCustomerPhone] = useState('');
  const total = useMemo(() => basket.reduce((n, x) => n + x.quantity, 0), [basket]);
  const validationReady = () => required.every(({ k, v }) => v !== 'required' || (validation[k] || '').trim());

  function changeQty(productId, delta) {
    const product = products.find((p) => p.id === productId);
    if (!product) return;
    setBasket((items) => {
      const current = items.find((x) => x.product.id === productId)?.quantity || 0;
      const next = Math.max(0, current + delta);
      if (items.some((x) => x.product.id === productId)) {
        return next ? items.map((x) => x.product.id === productId ? { ...x, quantity: next } : x) : items.filter((x) => x.product.id !== productId);
      }
      return next ? [...items, { product, quantity: next }] : items;
    });
    setErr(null); sound.unlock();
  }

  async function submit() {
    if (!basket.length || !customerName.trim() || !validationReady()) return;
    setBusy(true); setErr(null);
    const idempotencySaleId = saleId;
    try {
      await rpc('record_basket_sale', {
        p_sale_id: idempotencySaleId, p_outlet_id: ctx.outletId,
        p_items: basket.map(({ product, quantity }) => ({ product_id: product.id, quantity })),
        p_device_ref: deviceRef(), p_validation: validation, p_client_time: new Date().toISOString(),
      }, { retries: 2 });
      await rpc('capture_sale_customer', { p_sale_id: idempotencySaleId, p_name: customerName.trim(), p_phone: customerPhone.trim() || null }, { retries: 2, timeoutMs: 12000 });
      const summary = basket.map((x) => `${x.product.name} × ${x.quantity}`).join(', ');
      onRecorded({ saleId: idempotencySaleId, stage: 'recorded', spinNo: 1, spinsAllowed: total, sku: summary, qty: total, outletId: ctx.outletId, at: Date.now() });
    } catch (e) {
      if (e.code === 'PENDING_HANDOVER' || e.code === 'SALE_IN_PROGRESS') { say('Complete the previous customer’s spins first', 'warn'); onPending(); return; }
      setErr(e.code === 'OUT_OF_STOCK' ? `PRIZE STOCK NEEDED: ${e.detail || ''}. Ask your supervisor to replenish.` : friendly(e));
    } finally { setBusy(false); }
  }

  return (
    <main className="sale sale-basket">
      <div className="picker-top"><button className="back" onClick={stage === 'customer' ? () => setStage('basket') : onBack}>‹</button><h2>{stage === 'customer' ? 'CUSTOMER DETAILS' : 'RECORD PURCHASE'}</h2></div>
      <div className="sale-outlet">📍 {ctx.outletName} · {ctx.tseName}</div>
      {stage === 'basket' ? <>
        <section className="basket-lines" aria-label="Rio products on customer bill">
          <div className="sku-list-heading"><div><h3>Customer’s bill</h3><p>Set the quantity for each product purchased.</p></div><span>QTY</span></div>
          <div className="sku-list">
            {products.map((product) => {
              const quantity = basket.find((item) => item.product.id === product.id)?.quantity || 0;
              return <div className={`sku-row${quantity ? ' selected' : ''}`} key={product.id}>
                <span className="sku-name">{product.name}</span>
                <div className="sku-stepper" aria-label={`${product.name} quantity`}>
                  <button aria-label={`Remove one ${product.name}`} disabled={!quantity} onClick={() => changeQty(product.id, -1)}>−</button>
                  <b aria-live="polite">{quantity}</b>
                  <button aria-label={`Add one ${product.name}`} onClick={() => changeQty(product.id, 1)}>+</button>
                </div>
              </div>;
            })}
            {!products.length && <p className="muted">No products are available for this outlet’s campaign.</p>}
          </div>
        </section>
        <div className="basket-total"><span>{total} {total === 1 ? 'item' : 'items'}</span><b>{total} {total === 1 ? 'spin' : 'spins'}</b></div>
        <button className="btn-primary big" disabled={!total} onClick={() => { setStage('customer'); setErr(null); }}>CONTINUE</button>
      </> : <div className="form validation">
        <div className="basket-total"><span>{total} {total === 1 ? 'item' : 'items'} on bill</span><b>{total} {total === 1 ? 'spin' : 'spins'}</b></div>
        <label>Customer name *<input autoComplete="name" value={customerName} onChange={(e) => setCustomerName(e.target.value)} required /></label>
        <label>Customer phone <small>(optional)</small><input type="tel" inputMode="tel" autoComplete="tel" value={customerPhone} onChange={(e) => setCustomerPhone(e.target.value)} /></label>
        {basket.map(({ product, quantity }) => <div className="basket-line compact" key={product.id}><span>{product.name}</span><b>× {quantity}</b></div>)}
        {required.map(({ k, v }) => <label key={k}>{LABELS[k] || k.replace(/_/g, ' ')}{v === 'required' ? ' *' : ''}<input value={validation[k] || ''} onChange={(e) => setValidation({ ...validation, [k]: e.target.value })} /></label>)}
        <button className="btn-primary big" disabled={busy || !customerName.trim() || !validationReady()} onClick={submit}>{busy ? 'RECORDING…' : 'RECORD BILL & START SPINS'}</button>
      </div>}
      {busy && <div className="busy">Recording sale…</div>}{err && <div className="err big">{err}</div>}
      {!online && <div className="err">Offline — a sale needs signal to record. Try again when connected.</div>}
    </main>
  );
}
