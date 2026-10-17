const norm = (v) => String(v ?? '').trim().replace(/\s+/g, ' ');

export function parseGlobalOutletWorkbook(rows) {
  if (!rows?.length) throw new Error('The outlet workbook is empty.');
  const header = rows[0].map((value) => norm(value).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim());
  const find = (...labels) => header.findIndex((value) => labels.includes(value));
  const stateCol = find('state', 'state code');
  const nameCol = find('outlet name', 'outlet name ');
  const routeCol = find('route', 'beat', 'route beat');
  const areaCol = find('area', 'market area');
  const licenseCol = find('licno', 'lic no', 'license no', 'license number', 'licence no', 'licence number');
  const addressCol = find('address', 'outlet address');
  const cityCol = find('market', 'city');
  if ([stateCol, nameCol, routeCol, areaCol, licenseCol].some((index) => index < 0)) {
    throw new Error('The first sheet must have State, Outlet NAME, ROUTE, AREA, and LICNO columns.');
  }
  const occurrences = new Map();
  const parsed = [];
  const citiesByIdentity = new Map();
  rows.slice(1).forEach((row, index) => {
    const stateRaw = norm(row[stateCol]).toUpperCase().replace(/[^A-Z]/g, '');
    const stateCode = ['UP', 'UTTARPRADESH'].includes(stateRaw) ? 'UP'
      : ['MH', 'MAHARASHTRA'].includes(stateRaw) ? 'MH' : '';
    const outletName = norm(row[nameCol]);
    const route = norm(row[routeCol]);
    const area = norm(row[areaCol]);
    const rawLicense = norm(row[licenseCol]);
    const licenseNo = rawLicense;
    const address = addressCol < 0 ? '' : norm(row[addressCol]);
    const city = cityCol < 0 ? '' : norm(row[cityCol]);
    if (!stateCode || !outletName) {
      if ([stateRaw, outletName, route, area, rawLicense].some(Boolean)) {
        throw new Error(`Row ${index + 2} needs a valid UP/MH state and outlet name.`);
      }
      return;
    }
    const identity = [stateCode, outletName, route, area, licenseNo, address].map((value) => value.normalize('NFKC').trim().replace(/\s+/g, ' ').toLocaleLowerCase('en')).join('\u001f');
    if (city && citiesByIdentity.has(identity) && citiesByIdentity.get(identity) !== city) {
      throw new Error(`Row ${index + 2} has conflicting MARKET / City values for the same outlet.`);
    }
    if (city) citiesByIdentity.set(identity, city);
    const duplicateOccurrence = (occurrences.get(identity) || 0) + 1;
    occurrences.set(identity, duplicateOccurrence);
    parsed.push({ state_code: stateCode, outlet_name: outletName, route, area, license_no: licenseNo, address, city, duplicate_occurrence: duplicateOccurrence });
  });
  if (!parsed.length) throw new Error('No valid outlet rows were found.');
  return parsed;
}

