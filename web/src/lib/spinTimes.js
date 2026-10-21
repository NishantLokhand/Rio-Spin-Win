const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
export function duration(seconds) {
  const minutes = Math.floor(Math.max(0, Number(seconds) || 0) / 60);
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`;
}
export function attachSpinTimes(rows, times = [], summary = false) {
  const byDate = new Map(times.map((t) => [`${t.key}:${t.date}`, t]));
  return rows.map((r) => {
    if (summary) return { ...r, first_spin_time: 'N/A', last_spin_time: 'N/A', activity_span: 'N/A' };
    const t = byDate.get(`${r.key}:${r.date}`);
    return { ...r, first_spin_time: t?.first_spin_at ? clock.format(new Date(t.first_spin_at)) : 'N/A',
      last_spin_time: t?.last_spin_at ? clock.format(new Date(t.last_spin_at)) : 'N/A',
      activity_span: t ? duration(t.activity_span_seconds) : Number(r.spins) > 0 ? 'N/A' : '0h 00m' };
  });
}
