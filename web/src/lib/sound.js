// Synthesised sounds (no audio files needed). Toggle persisted per device.
import { store } from './store.js';

let ctx;
const ac = () => {
  if (!ctx) { const C = window.AudioContext || window.webkitAudioContext; if (!C) return null; ctx = new C(); }
  if (ctx.state === 'suspended') ctx.resume();
  return ctx;
};

export const sound = {
  enabled() { return store.get('rio.sound', true); },
  set(on) { store.set('rio.sound', !!on); },
  unlock() { ac(); },
  tone(freq, dur = 0.08, type = 'square', vol = 0.05, when = 0) {
    if (!this.enabled()) return;
    const c = ac(); if (!c) return;
    const t = c.currentTime + when;
    const o = c.createOscillator(); const g = c.createGain();
    o.type = type; o.frequency.setValueAtTime(freq, t);
    g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(g).connect(c.destination); o.start(t); o.stop(t + dur + 0.02);
  },
  tick() { this.tone(1400, 0.03, 'square', 0.03); },
  whoosh() { [220, 330, 440].forEach((f, i) => this.tone(f, 0.25, 'sawtooth', 0.02, i * 0.05)); },
  win() { [523, 659, 784, 1047].forEach((f, i) => this.tone(f, 0.18, 'triangle', 0.08, i * 0.1)); },
  big() { [523, 659, 784, 1047, 784, 1047, 1319].forEach((f, i) => this.tone(f, 0.22, 'triangle', 0.09, i * 0.11)); },
  jackpot() {
    const seq = [523, 523, 659, 784, 659, 784, 1047, 1047, 1319, 1568];
    seq.forEach((f, i) => { this.tone(f, 0.25, 'square', 0.06, i * 0.13); this.tone(f / 2, 0.25, 'triangle', 0.06, i * 0.13); });
  },
};
