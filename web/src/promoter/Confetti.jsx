import React, { useEffect, useRef } from 'react';

const COLORS = ['#FF2E63', '#FFD23F', '#08D9D6', '#7B2FF7', '#FF8A00', '#2BD66B', '#ffffff'];
const POWER = { standard: { n: 90, bursts: 1 }, mid: { n: 160, bursts: 2 }, high: { n: 220, bursts: 3 }, jackpot: { n: 320, bursts: 7 } };

/** Canvas confetti; intensity scales with prize tier */
export default function Confetti({ tier = 'standard' }) {
  const ref = useRef(null);
  useEffect(() => {
    const cv = ref.current; const ctx = cv.getContext('2d');
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const resize = () => { cv.width = innerWidth * dpr; cv.height = innerHeight * dpr; };
    resize(); addEventListener('resize', resize);
    const cfg = POWER[tier] || POWER.standard;
    let parts = []; let raf; let alive = true;
    const burst = (x, y) => {
      for (let i = 0; i < cfg.n; i++) {
        const a = Math.random() * Math.PI * 2; const v = 6 + Math.random() * (tier === 'jackpot' ? 16 : 11);
        parts.push({ x: x * dpr, y: y * dpr, vx: Math.cos(a) * v * dpr, vy: (Math.sin(a) * v - 7) * dpr,
          s: (5 + Math.random() * 7) * dpr, r: Math.random() * 6, vr: (Math.random() - 0.5) * 0.4,
          c: COLORS[(Math.random() * COLORS.length) | 0], life: 1, shape: Math.random() < 0.3 ? 'c' : 'r' });
      }
    };
    const timers = [];
    for (let b = 0; b < cfg.bursts; b++) {
      timers.push(setTimeout(() => alive && burst(innerWidth * (0.2 + Math.random() * 0.6), innerHeight * (0.25 + Math.random() * 0.2)), b * 420));
    }
    const step = () => {
      ctx.clearRect(0, 0, cv.width, cv.height);
      parts.forEach((p) => {
        p.vy += 0.35 * dpr; p.vx *= 0.985; p.vy *= 0.985; p.x += p.vx; p.y += p.vy; p.r += p.vr; p.life -= 0.004;
        ctx.save(); ctx.globalAlpha = Math.max(p.life, 0); ctx.translate(p.x, p.y); ctx.rotate(p.r); ctx.fillStyle = p.c;
        if (p.shape === 'c') { ctx.beginPath(); ctx.arc(0, 0, p.s / 2, 0, 7); ctx.fill(); } else ctx.fillRect(-p.s / 2, -p.s / 4, p.s, p.s / 2);
        ctx.restore();
      });
      parts = parts.filter((p) => p.life > 0 && p.y < cv.height + 40);
      raf = requestAnimationFrame(step);
    };
    step();
    return () => { alive = false; cancelAnimationFrame(raf); timers.forEach(clearTimeout); removeEventListener('resize', resize); };
  }, [tier]);
  return <canvas ref={ref} className="confetti" aria-hidden />;
}
