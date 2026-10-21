import { performanceColumns } from './performanceMetrics.js';

const number = (v) => v == null ? '—' : Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 });
const money = (v) => v == null ? '—' : `₹${number(v)}`;
export const userPerformanceColumns = [
  { key: 'date', label: 'Date' }, { key: 'label', label: 'User' }, { key: 'user_type', label: 'Type' },
  { key: 'state', label: 'State' }, { key: 'city', label: 'City' }, { key: 'area', label: 'Area' },
  { key: 'outlets', label: 'Outlets Visited' }, { key: 'active_outlets', label: 'Outlets Covered', align: 'r' },
  { key: 'spins', label: 'Spins', align: 'r', fmt: number }, { key: 'units', label: 'Units Sold', align: 'r', fmt: number },
  { key: 'first_spin_time', label: 'First spin time (IST)' },
  { key: 'last_spin_time', label: 'Last spin time (IST)' },
  { key: 'activity_span', label: 'Activity span' },
  { key: 'giveaway_cost', label: 'Giveaway Cost', align: 'r', fmt: money },
  { key: 'avg_cost', label: 'Average Cost', align: 'r', fmt: money },
  { key: 'user_code', label: 'User Code' }, ...performanceColumns,
];

export function userReportColumns(extras = []) {
  const keys = new Set(userPerformanceColumns.map((c) => c.key));
  return [...userPerformanceColumns, ...extras.filter((c) => {
    if (keys.has(c.key)) return false;
    keys.add(c.key); return true;
  })];
}
