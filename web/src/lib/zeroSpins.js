export function zeroSpinUsers(users, profiles, activity, dates = {}, people = []) {
  const counts = new Map();
  for (const row of activity) {
    const spins = Number(row.spins);
    if (!Number.isFinite(spins) || spins < 0) throw new Error('Invalid spin count. Refresh and try again.');
    counts.set(row.key, (counts.get(row.key) || 0) + spins);
  }
  const byUser = new Map(profiles.map((p) => [p.user_id, p]));
  const cities = new Map(people.filter((p) => p.auth_user_id).map((p) => [
    p.auth_user_id, String(p.market_override ?? p.market_raw ?? '').trim(),
  ]));
  return users.filter((u) => byUser.has(u.id) && !(counts.get(u.id) > 0)).map((u) => ({
    id: u.id, name: u.full_name, login: u.login_id,
    code: byUser.get(u.id).promoter_code, type: byUser.get(u.id).promoter_type,
    city: cities.get(u.id) || '',
    status: u.is_active ? 'Active' : 'Disabled', spins: 0,
    date_from: dates.date_from || 'Beginning', date_to: dates.date_to || 'No end date',
  }));
}
