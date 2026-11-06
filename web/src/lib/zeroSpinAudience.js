// Zero-spin reporting only. Older server policies intentionally allow some
// demo logins for prize testing; that exception must not add missing workdays.
export function isZeroSpinDemoAccount(user) {
  const login = String(user.login_id ?? '').trim();
  const name = String(user.full_name ?? '').trim();
  return /^(demo|test)([^a-z]|$)/i.test(login)
    || /(^|[^a-z0-9])(demo|test)([^a-z]|$)/i.test(name);
}

export function zeroSpinAudience(users, people, userType = '') {
  const matching = userType ? new Set(people.filter(p => p.designation === userType).map(p => p.auth_user_id)) : null;
  return users.filter(user => !isZeroSpinDemoAccount(user) && (!matching || matching.has(user.id)));
}

export function zeroSpinReportSource(source) {
  return { ...source, users: zeroSpinAudience(source.users, source.people) };
}
