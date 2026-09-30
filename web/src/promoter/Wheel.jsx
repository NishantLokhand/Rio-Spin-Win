import React, { forwardRef, useImperativeHandle, useRef, useEffect } from 'react';
import { sound } from '../lib/sound.js';

// Visual wheel ONLY. Segments do not reflect odds — the server decides the prize,
// and the wheel is steered to land on a segment that matches it.
export const SEGMENTS = [
  { label: '₹5 SNACK', lines: ['₹5', 'SNACK'], color: '#FF2E63', text: '#fff' },
  { label: '₹10 SNACK', lines: ['₹10', 'SNACK'], color: '#FFD23F', text: '#35250D' },
  { label: 'RIO DARE CARD GAME', lines: ['RIO DARE', 'CARD GAME'], color: '#7B2FF7', text: '#fff' },
  { label: 'RIO SUNGLASSES', lines: ['RIO', 'SUNGLASSES'], color: '#08D9D6', text: '#35250D' },
  { label: 'RIO MINI BLUETOOTH SPEAKER', lines: ['RIO MINI', 'BLUETOOTH', 'SPEAKER'], color: '#FF8A00', text: '#35250D' },
];
const N = SEGMENTS.length;
const SEG = 360 / N;
const R = 180;

function arc(i) {
  const a0 = ((i * SEG - 90) * Math.PI) / 180;
  const a1 = (((i + 1) * SEG - 90) * Math.PI) / 180;
  return `M0 0 L${R * Math.cos(a0)} ${R * Math.sin(a0)} A${R} ${R} 0 0 1 ${R * Math.cos(a1)} ${R * Math.sin(a1)} Z`;
}

const easeOutQuint = (t) => 1 - Math.pow(1 - t, 5);

const Wheel = forwardRef(function Wheel({ onSwipe, disabled }, ref) {
  const gRef = useRef(null);
  const st = useRef({ angle: 0, vel: 0, mode: 'idle', raf: 0, lastSeg: 0, lastT: 0, idleVel: 0 });

  const apply = () => { if (gRef.current) gRef.current.setAttribute('transform', `rotate(${st.current.angle % 360})`); };

  const loop = (t) => {
    const s = st.current;
    const dt = s.lastT ? Math.min((t - s.lastT) / 1000, 0.05) : 0;
    s.lastT = t;
    if (s.mode === 'idle') s.angle += s.idleVel * dt;
    else if (s.mode === 'free') { s.vel = Math.min(s.vel + 900 * dt, 540); s.angle += s.vel * dt; }
    else if (s.mode === 'land') {
      const p = Math.min((t - s.t0) / s.T, 1);
      s.angle = s.a0 + s.D * easeOutQuint(p);
      if (p >= 1) { s.mode = 'stopped'; apply();
        const under = (((-s.angle) % 360) + 360) % 360; console.debug('[wheel] landed', SEGMENTS[Math.floor(under / SEG)].label); const done = s.onDone; s.onDone = null; setTimeout(() => done && done(), 250); }
    }
    const seg = Math.floor(s.angle / SEG);
    if (seg !== s.lastSeg && s.mode !== 'idle') { s.lastSeg = seg; sound.tick(); }
    apply();
    if (s.mode !== 'stopped') s.raf = requestAnimationFrame(loop);
  };

  useEffect(() => {
    st.current.raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(st.current.raf);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useImperativeHandle(ref, () => ({
    start() { const s = st.current; const wasStopped = s.mode === 'stopped'; s.mode = 'free'; s.vel = Math.max(s.vel, 160); if (wasStopped) s.raf = requestAnimationFrame(loop); },
    pause() { const s = st.current; s.mode = 'stopped'; cancelAnimationFrame(s.raf); apply(); },
    /** land on one of the allowed segment labels; resolves when stopped */
    landOn(labels) {
      return new Promise((resolve) => {
        const s = st.current;
        const allowed = SEGMENTS.map((x, i) => ({ ...x, i })).filter((x) => labels.includes(x.label));
        const pick = allowed.length ? allowed[Math.floor(Math.random() * allowed.length)] : { i: 0 };
        const center = pick.i * SEG + SEG / 2;
        const jitter = (Math.random() - 0.5) * SEG * 0.6;
        const v0 = Math.max(Math.min(s.vel, 540), 420);
        // Quintic ease-out begins at v0 and eases its acceleration into a gentle stop.
        const base = v0;
        const a0 = s.angle;
        const want = ((((-(center + jitter)) - (a0 + base)) % 360) + 360) % 360;
        const D = base + want;
        s.a0 = a0; s.D = D; s.T = (5 * D / v0) * 1000; s.t0 = performance.now(); s.mode = 'land'; s.onDone = resolve;
      });
    },
    reset() {
      const s = st.current; const wasStopped = s.mode === 'stopped';
      s.mode = 'idle'; s.vel = 0; s.lastT = 0;
      if (wasStopped) s.raf = requestAnimationFrame(loop);
    },
  }));

  // swipe to spin
  const touch = useRef(null);
  const down = (e) => { touch.current = { x: e.clientX, y: e.clientY, t: Date.now() }; };
  const up = (e) => {
    const t0 = touch.current; touch.current = null;
    if (!t0 || disabled) return;
    const d = Math.hypot(e.clientX - t0.x, e.clientY - t0.y);
    if (d > 45 && Date.now() - t0.t < 900) onSwipe && onSwipe();
  };

  const bulbs = Array.from({ length: 24 }, (_, i) => {
    const a = (i * 15 * Math.PI) / 180;
    return <circle key={i} className={`bulb ${i % 2 ? 'b2' : 'b1'}`} cx={197 * Math.cos(a)} cy={197 * Math.sin(a)} r="5" />;
  });

  return (
    <div className="wheel-wrap" onPointerDown={down} onPointerUp={up} style={{ touchAction: 'none' }}>
      <svg viewBox="-215 -225 430 440" className="wheel-svg" role="img" aria-label="Prize wheel">
        <defs>
          <radialGradient id="hub" cx="50%" cy="40%"><stop offset="0%" stopColor="#3a1d78" /><stop offset="100%" stopColor="#1B0B3A" /></radialGradient>
          <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="6" stdDeviation="8" floodOpacity="0.45" /></filter>
        </defs>
        <circle r="208" fill="#1B0B3A" filter="url(#shadow)" />
        <circle r="202" fill="none" stroke="#FFD23F" strokeWidth="6" />
        {bulbs}
        <g ref={gRef}>
          {SEGMENTS.map((s, i) => (
            <g key={i}>
              <path d={arc(i)} fill={s.color} stroke="#1B0B3A" strokeWidth="3" />
              <g transform={`rotate(${i * SEG + SEG / 2}) translate(0 -${R * 0.58})`}>
                <text textAnchor="middle" fill={s.text} className="seg-text">
                  {s.lines.map((line, index) => <tspan key={line} x="0" dy={index === 0 ? `${-(s.lines.length - 1) * 8}px` : '16px'}>{line}</tspan>)}
                </text>
              </g>
            </g>
          ))}
        </g>
        <circle r="46" fill="url(#hub)" stroke="#FFD23F" strokeWidth="5" />
        <text textAnchor="middle" dy="10" className="hub-text">RIO</text>
        <path d="M-20 -222 L20 -222 L0 -178 Z" fill="#FFD23F" stroke="#1B0B3A" strokeWidth="4" strokeLinejoin="round" />
      </svg>
    </div>
  );
});

export default Wheel;
