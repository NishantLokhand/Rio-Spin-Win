export function shiftDate(date, days) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function historyRange(mode, end) {
  if (mode === 'monthly') return { from: `${end.slice(0, 7)}-01`, to: end };
  if (mode === 'weekly') {
    const weekday = new Date(`${end}T00:00:00Z`).getUTCDay();
    return { from: shiftDate(end, -((weekday + 6) % 7)), to: end };
  }
  return { from: '', to: end };
}
