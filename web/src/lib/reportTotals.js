// Only additive measures belong in totals. Distinct outlet/promoter counts can
// overlap between rows and must not be summed.
export function reportTotal(rows, prize = false) {
  const total = { label: 'TOTAL' };
  const keys = prize ? ['quantity', 'total_cost', 'handed_over', 'pending']
    : ['sales', 'spins', 'units', 'giveaway_cost', 'prizes_given'];
  for (const key of keys) total[key] = rows.reduce((sum, row) => sum + Number(row[key] || 0), 0);
  if (prize) total.unit_cost = total.quantity ? total.total_cost / total.quantity : 0;
  else total.avg_cost = total.spins ? total.giveaway_cost / total.spins : 0;
  return total;
}

export function reportPeriod(filters) {
  const display = (date) => date.split('-').reverse().join('/');
  return !filters.date_from && !filters.date_to ? 'All dates'
    : `${filters.date_from ? display(filters.date_from) : 'Beginning'} – ${filters.date_to ? display(filters.date_to) : 'No end date'}`;
}
