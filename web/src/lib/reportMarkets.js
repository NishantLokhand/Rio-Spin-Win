const text = value => String(value ?? '').trim();

// Market describes the user's home market, separately from visited City/Area.
// The supplied master takes precedence; new users use their linked org profile.
// Never infer a user's market from their name or an outlet location.
export function profileMarket(person = {}) {
  return text(person.market_override ?? person.market_raw);
}

export function reportMarketLookup({ people = [], markets = [] } = {}) {
  const org = new Map(people.map(p => [p.auth_user_id, p]));
  const resolved = new Map(markets.map(m => [m.user_id, m.market]));
  return id => resolved.get(id) ?? profileMarket(org.get(id));
}

export function attachReportMarkets(rows, lookup, userKey = 'key') {
  return rows.map(row => ({ ...row, market: lookup(row[userKey], row) }));
}
