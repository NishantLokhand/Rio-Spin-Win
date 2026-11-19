export function requireFieldUserMarket(role, market) {
  if (role !== 'promoter') return '';
  if (typeof market !== 'string' || !market.trim()) {
    throw new Error('Market is required for new field users');
  }
  return market.trim();
}
