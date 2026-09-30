// Create promoter-role logins for existing PROMOTER, TSE and MER master rows.
// Reads mobile numbers from the consolidated inventory workbook, but never
// creates organizational master records or assigns outlets/stock.
import { createClient } from '@supabase/supabase-js';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const workbookPath = path.join(root, 'source_file', 'MH-UP inventory DETAILS.xlsx');
const envPath = path.join(root, 'web', '.env.local');
const envValues = fs.existsSync(envPath)
  ? Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .filter((line) => line.includes('=') && !line.trim().startsWith('#'))
    .map((line) => [line.slice(0, line.indexOf('=')).trim(), line.slice(line.indexOf('=') + 1).trim()]))
  : {};
const require = createRequire(path.join(root, 'web', 'package.json'));
let XLSX;
try { XLSX = require('xlsx'); }
catch { throw new Error('Workbook reader is missing. First run: npm --prefix web install'); }

function ask(prompt) {
  return new Promise((resolve) => {
    process.stdout.write(prompt);
    process.stdin.setEncoding('utf8');
    process.stdin.once('data', (value) => resolve(String(value).trim()));
  });
}

function askSecret(prompt) {
  return new Promise((resolve, reject) => {
    const input = process.stdin;
    if (!input.isTTY || typeof input.setRawMode !== 'function') {
      reject(new Error('Run from an interactive Command Prompt or PowerShell window.'));
      return;
    }
    let value = '';
    process.stdout.write(prompt);
    input.setEncoding('utf8'); input.setRawMode(true); input.resume();
    const finish = (error) => {
      input.setRawMode(false); input.pause(); input.removeListener('data', onData); process.stdout.write('\n');
      error ? reject(error) : resolve(value);
    };
    const onData = (key) => {
      if (key === '\u0003') return finish(new Error('Cancelled.'));
      if (key === '\r' || key === '\n') return finish();
      if (key === '\u007f' || key === '\b') { if (value.length) { value = value.slice(0, -1); process.stdout.write('\b \b'); } return; }
      if (key >= ' ') { value += key; process.stdout.write('*'); }
    };
    input.on('data', onData);
  });
}

const norm = (value) => String(value ?? '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
  .replace(/\s+/g, ' ').trim().toUpperCase();
const digits = (value) => String(value ?? '').replace(/\D/g, '');
const csvCell = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;

function readRoster() {
  if (!fs.existsSync(workbookPath)) throw new Error(`Workbook not found: ${workbookPath}`);
  const workbook = XLSX.readFile(workbookPath, { cellDates: false });
  for (const sheetName of workbook.SheetNames) {
    const rows = XLSX.utils.sheet_to_json(workbook.Sheets[sheetName], { header: 1, defval: '', raw: false });
    const headerAt = rows.findIndex((row) => {
      const labels = row.map((v) => norm(v).replace(/[^A-Z0-9]/g, ''));
      return labels.includes('EMPLOYEENAME') && labels.includes('DESIGNATION') && labels.includes('MOBNO');
    });
    if (headerAt < 0) continue;
    const labels = rows[headerAt].map((v) => norm(v).replace(/[^A-Z0-9]/g, ''));
    const ix = Object.fromEntries(labels.map((label, index) => [label, index]));
    const roster = [];
    for (let i = headerAt + 1; i < rows.length; i += 1) {
      const row = rows[i];
      const designation = norm(row[ix.DESIGNATION]);
      if (!['PROMOTER', 'TSE', 'MER'].includes(designation)) continue;
      roster.push({
        rowNumber: i + 1,
        name: String(row[ix.EMPLOYEENAME] ?? '').trim(),
        designation,
        mobile: digits(row[ix.MOBNO]),
        fasId: String(row[ix.FASID] ?? '').trim(),
        qaId: String(row[ix.QAEMPID] ?? '').trim(),
      });
    }
    return roster;
  }
  throw new Error('Could not find the employee name, designation and mobile columns in the workbook.');
}

async function pages(query) {
  const all = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await query.range(from, from + 999);
    if (error) throw error;
    all.push(...(data || []));
    if (!data || data.length < 1000) return all;
  }
}

const roster = readRoster();
const seenMobiles = new Set();
for (const person of roster) {
  if (!person.name || person.mobile.length !== 10) person.preflight = 'Invalid name or 10-digit mobile';
  else if (seenMobiles.has(person.mobile)) person.preflight = 'Duplicate mobile in workbook';
  else seenMobiles.add(person.mobile);
}

let createdIds = [];
let linkedMasterIds = [];
let sb;
let csvPath;
try {
  const url = process.env.SUPABASE_URL || envValues.VITE_SUPABASE_URL || await ask('Supabase project URL: ');
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || await askSecret('Supabase service-role / secret key (hidden): ');
  if (!url.startsWith('https://') || !serviceKey) throw new Error('A valid Supabase URL and service-role key are required.');
  sb = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const [masterPeople, users] = await Promise.all([
    pages(sb.from('org_people').select('id,designation,employee_name,mobile,fas_id,qa_employee_id,auth_user_id').order('employee_name')),
    pages(sb.from('app_users').select('id,role,login_id,full_name,mobile')),
  ]);
  const existingByLogin = new Map(users.map((user) => [digits(user.login_id), user]));
  const usersById = new Map(users.map((user) => [user.id, user]));
  const createdCredentials = [];
  const reportRows = [['Workbook row', 'Name', 'Master designation', 'Mobile / login', 'Initial password', 'Status']];
  let passwordOrdinal = 0;

  for (const person of roster) {
    if (person.preflight) {
      reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', person.preflight]);
      continue;
    }
    const sameDesignation = masterPeople.filter((p) => p.designation === person.designation);
    let matches = [];
    if (person.fasId) matches = sameDesignation.filter((p) => norm(p.fas_id) === norm(person.fasId));
    if (matches.length !== 1 && person.qaId) matches = sameDesignation.filter((p) => norm(p.qa_employee_id) === norm(person.qaId));
    if (matches.length !== 1) matches = sameDesignation.filter((p) => norm(p.employee_name) === norm(person.name));
    if (matches.length !== 1) {
      reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', matches.length ? 'Ambiguous master match — skipped' : 'No existing master match — skipped']);
      continue;
    }
    const master = matches[0];
    const initialPassword = String(111111 + passwordOrdinal++);
    const existingLogin = existingByLogin.get(person.mobile);
    if (existingLogin) {
      if (existingLogin.role !== 'promoter') {
        reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', 'Login already exists with another app role — skipped']);
        continue;
      }
      if (master.auth_user_id && master.auth_user_id !== existingLogin.id) {
        reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', 'Master record linked to a different login — skipped']);
        continue;
      }
      const promoter = await sb.from('promoters').select('user_id').eq('user_id', existingLogin.id).maybeSingle();
      if (promoter.error) throw promoter.error;
      if (!promoter.data) {
        reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', 'Existing promoter-role login lacks required profile — skipped']);
        continue;
      }
      if (!master.auth_user_id) {
        const { error } = await sb.from('org_people').update({ auth_user_id: existingLogin.id }).eq('id', master.id).is('auth_user_id', null);
        if (error) throw error;
        linkedMasterIds.push(master.id);
      }
      reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', 'Existing login verified; password unchanged']);
      continue;
    }
    if (master.auth_user_id) {
      const linkedUser = usersById.get(master.auth_user_id);
      reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, '', `Master record already linked to ${linkedUser?.login_id || 'another login'} — skipped`]);
      continue;
    }

    const emailDomain = envValues.VITE_LOGIN_DOMAIN || 'login.riospinwin.app';
    const email = `${person.mobile}@${emailDomain}`;
    const auth = await sb.auth.admin.createUser({
      email, password: initialPassword, email_confirm: true,
      app_metadata: { app_role: 'promoter', source_designation: person.designation },
      user_metadata: { full_name: person.name },
    });
    if (auth.error) throw new Error(`Create login for workbook row ${person.rowNumber}: ${auth.error.message}`);
    const userId = auth.data.user.id;
    createdIds.push(userId);
    const { error: appError } = await sb.from('app_users').insert({
      id: userId, role: 'promoter', login_id: person.mobile, full_name: person.name, mobile: person.mobile,
    });
    if (appError) throw new Error(`Create app profile for ${person.mobile}: ${appError.message}`);
    const { error: profileError } = await sb.from('promoters').insert({
      user_id: userId, promoter_code: `STAFF-${person.mobile}`, promoter_type: 'temporary',
    });
    if (profileError) throw new Error(`Create promoter login profile for ${person.mobile}: ${profileError.message}`);
    const { error: linkError } = await sb.from('org_people').update({ auth_user_id: userId }).eq('id', master.id).is('auth_user_id', null);
    if (linkError) throw new Error(`Link existing ${person.designation} master row for ${person.mobile}: ${linkError.message}`);
    linkedMasterIds.push(master.id);
    createdCredentials.push({ name: person.name, designation: person.designation, mobile: person.mobile, password: initialPassword });
    existingByLogin.set(person.mobile, { id: userId, role: 'promoter', login_id: person.mobile });
    usersById.set(userId, { id: userId, role: 'promoter', login_id: person.mobile });
    reportRows.push([person.rowNumber, person.name, person.designation, person.mobile, initialPassword, 'Created app login role: promoter']);
  }

  csvPath = path.join(root, 'staff-login-credentials.local.csv');
  fs.writeFileSync(csvPath, `${reportRows.map((row) => row.map(csvCell).join(',')).join('\r\n')}\r\n`, { encoding: 'utf8', flag: 'w' });
  const skipped = reportRows.slice(1).filter((row) => !String(row[5]).startsWith('Created') && !String(row[5]).startsWith('Existing')).length;
  console.log(`Finished: ${createdCredentials.length} new promoter-role logins created; ${roster.length - createdCredentials.length - skipped} existing logins retained; ${skipped} skipped for review.`);
  console.log(`Private login/password report: ${csvPath}`);
  console.log('TSE and MER retain their master designations but receive app role promoter. No outlet access or prize stock is added by this script.');
} catch (error) {
  if (sb) {
    for (const id of [...linkedMasterIds].reverse()) await sb.from('org_people').update({ auth_user_id: null }).eq('id', id).catch(() => {});
    for (const id of [...createdIds].reverse()) await sb.auth.admin.deleteUser(id).catch(() => {});
  }
  console.error(`\nStaff login setup failed and newly created accounts were rolled back where possible: ${error.message}`);
  process.exitCode = 1;
}
