import React, { useState } from 'react';
import { rpc, friendly } from '../lib/api.js';
import { uuid, deviceRef } from '../lib/store.js';
import { sound } from '../lib/sound.js';

const QTY = [1, 2, 3, 4, 5, 6, 8, 12];
const LABELS = { invoice_no: 'Invoice number', receipt_no: 'Receipt number', qr_code: 'QR code', barcode: 'Product barcode' };

// START NEW SALE → select regional SKU and quantity → capture name → customer spins.
export default function SaleFlow({ ctx, products, online, onRecorded, onBack, onPending, say }) {
  const [sku, setSku] = useState(null);
  const [qty, setQty] = useState(null);
  const [custom, setCustom] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [saleId] = useState(() => uuid());   // one id per sale attempt → retries never double-record
  const rules = ctx.campaign?.validation_rules || {};
  const required = Object.entries(rules).filter(([, v]) => v === 'required' || v === 'optional').map(([k, v]) => ({ k, v }));
  const [validation, setValidation] = useState({});
  const [customerName, setCustomerName] = useState('');
  const [customerPhone, setCustomerPhone] = useState('');
  const maxQty = ctx.campaign?.max_quantity_per_sale || 24;

  async function record(q) {
    sound.unlock();
    setQty(q);
    if (required.length && !validationReady()) return;       // show validation fields first
  }
  const validationReady = () => required.every(({ k, v }) => v !== 'required' || (validation[k] || '').trim());

  async function submit(q = qty) {
    setBusy(true); setErr(null);
    try {
      await rpc('record_sale', {
        p_sale_id: saleId, p_outlet_id: ctx.outletId, p_product_id: sku.id, p_quantity: q,
        p_device_ref: deviceRef(), p_validation: validation, p_client_time: new Date().toISOString(),
      }, { retries: 2 });
      await rpc('capture_sale_customer', { p_sale_id: saleId, p_name: customerName.trim(), p_phone: customerPhone.trim() || null }, { retries: 2, timeoutMs: 12000 });
      onRecorded({ saleId, stage: 'recorded', spinNo: 1, sku: sku.name, qty: q, outletId: ctx.outletId, at: Date.now() });
    } catch (e) {
      if (e.code === 'PENDING_HANDOVER') { say('Hand over the previous prize first', 'warn'); onPending(); return; }
      setErr(e.code === 'OUT_OF_STOCK' ? `PRIZE STOCK NEEDED: ${e.detail || ''}. Ask your supervisor to replenish.` : friendly(e));
      setQty(null);
    } finally { setBusy(false); }
  }

  return (
    <main className="sale">
      <div className="picker-top">
        <button className="back" onClick={sku ? () => { setSku(null); setQty(null); setErr(null); } : onBack}>‹</button>
        <h2>{!sku ? 'WHICH RIO?' : qty ? 'CUSTOMER DETAILS' : 'HOW MANY?'}</h2>
      </div>
      <div className="sale-outlet">📍 {ctx.outletName} · {ctx.tseName}</div>

      {!sku && (
        <div className="sku-grid">
          {products.map((p, i) => (
            <button key={p.id} className={`sku c${i % 4}`} onClick={() => setSku(p)}>
              <span className="sku-can" aria-hidden="true">🥫</span>
              <b>{p.name}</b>
            </button>
          ))}
          {!products.length && <p className="muted">No products loaded. Check connection.</p>}
        </div>
      )}

      {sku && (
        <>
          <div className="sku-chosen">{sku.name}</div>
          {!qty && <>
            <div className="qty-grid">
              {QTY.filter((n) => n <= maxQty).map((n) => (
                <button key={n} className="qty" disabled={busy} onClick={() => record(n)}>{n}</button>
              ))}
            </div>
            <div className="qty-custom">
              <input type="number" inputMode="numeric" min="1" max={maxQty} placeholder="Other qty" value={custom}
                     onChange={(e) => setCustom(e.target.value)} />
              <button className="btn-secondary" disabled={busy || !(+custom >= 1 && +custom <= maxQty)} onClick={() => record(+custom)}>OK</button>
            </div>
          </>}

          {qty && (
            <div className="form validation">
              <label>Customer name *
                <input autoComplete="name" value={customerName} onChange={(e) => setCustomerName(e.target.value)} required />
              </label>
              <label>Customer phone <small>(optional)</small>
                <input type="tel" inputMode="tel" autoComplete="tel" value={customerPhone} onChange={(e) => setCustomerPhone(e.target.value)} />
              </label>
              <button className="btn-secondary" type="button" disabled={busy} onClick={() => setQty(null)}>CHANGE QUANTITY</button>
              {required.map(({ k, v }) => (
                <label key={k}>{LABELS[k] || k.replace(/_/g, ' ')}{v === 'required' ? ' *' : ''}
                  <input value={validation[k] || ''} onChange={(e) => setValidation({ ...validation, [k]: e.target.value })} />
                </label>
              ))}
              <button className="btn-primary big" disabled={busy || !customerName.trim() || !validationReady()} onClick={() => submit()}>CONTINUE TO SPIN</button>
            </div>
          )}
        </>
      )}

      {busy && <div className="busy">Recording sale…</div>}
      {err && <div className="err big">{err}</div>}
      {!online && <div className="err">Offline — a sale needs signal to record. Try again when connected.</div>}
    </main>
  );
}
