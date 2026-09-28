// Supabase Edge Function: admin-users
// Creates users, resets PINs and enables/disables logins. Only callable by an active admin.
// Deploy:  supabase functions deploy admin-users
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (provided automatically), LOGIN_DOMAIN (optional)
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const LOGIN_DOMAIN = Deno.env.get('LOGIN_DOMAIN') ?? 'login.riospinwin.app';
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const loginEmail = (id: string) => `${String(id).trim().toLowerCase().replace(/\s+/g, '').replace(/^\+91/, '')}@${LOGIN_DOMAIN}`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

    // 1. verify caller is an active admin
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: 'Not signed in' }, 401);
    const { data: me } = await admin.from('app_users').select('role,is_active').eq('id', user.id).single();
    if (!me || me.role !== 'admin' || !me.is_active) return json({ error: 'Admin only' }, 403);

    const body = await req.json();
    const audit = (action: string, entity_id: string, details: Record<string, unknown>) =>
      admin.rpc('write_audit_as', { p_actor: user.id, p_action: action, p_entity: 'app_users', p_entity_id: entity_id, p_details: details });

    if (body.action === 'create') {
      const { role, login_id, pin, full_name } = body;
      if (!['promoter', 'supervisor', 'admin'].includes(role)) return json({ error: 'Invalid role' }, 400);
      if (!login_id || !full_name) return json({ error: 'Login ID and name are required' }, 400);
      if (!pin || String(pin).length < 6) return json({ error: 'PIN must be at least 6 characters' }, 400);
      if (role === 'promoter' && !body.promoter?.promoter_code) return json({ error: 'Promoter code is required' }, 400);

      const { data: created, error } = await admin.auth.admin.createUser({
        email: loginEmail(login_id), password: String(pin), email_confirm: true,
        app_metadata: { app_role: role }, user_metadata: { full_name },
      });
      if (error) return json({ error: error.message.includes('already') ? 'That login ID already exists' : error.message }, 400);
      const id = created.user.id;

      const { error: e1 } = await admin.from('app_users').insert({
        id, role, login_id: String(login_id).trim().toLowerCase(), full_name, mobile: body.mobile ?? null,
        can_approve_outlets: !!body.can_approve_outlets, can_override_cost_target: !!body.can_override_cost_target,
      });
      if (e1) { await admin.auth.admin.deleteUser(id); return json({ error: e1.message }, 400); }
      if (role === 'promoter') {
        const p = body.promoter;
        const { error: e2 } = await admin.from('promoters').insert({
          user_id: id, promoter_code: p.promoter_code, promoter_type: p.promoter_type ?? 'permanent',
          agency_name: p.agency_name ?? null, supervisor_id: p.supervisor_id ?? null, home_state_id: p.home_state_id ?? null,
        });
        if (e2) { await admin.from('app_users').delete().eq('id', id); await admin.auth.admin.deleteUser(id); return json({ error: e2.message }, 400); }
      }
      await audit('USER_CREATED', id, { role, login_id, full_name });
      return json({ ok: true, id });
    }

    if (body.action === 'reset_pin') {
      if (!body.pin || String(body.pin).length < 6) return json({ error: 'PIN must be at least 6 characters' }, 400);
      const { error } = await admin.auth.admin.updateUserById(body.user_id, { password: String(body.pin) });
      if (error) return json({ error: error.message }, 400);
      await audit('USER_PIN_RESET', body.user_id, {});
      return json({ ok: true });
    }

    if (body.action === 'set_active') {
      const active = !!body.active;
      if (body.user_id === user.id && !active) return json({ error: 'You cannot disable yourself' }, 400);
      const { error } = await admin.from('app_users').update({ is_active: active }).eq('id', body.user_id);
      if (error) return json({ error: error.message }, 400);
      // ban blocks new logins and token refresh; app also re-checks is_active on every call
      await admin.auth.admin.updateUserById(body.user_id, { ban_duration: active ? 'none' : '876000h' });
      await audit(active ? 'USER_ENABLED' : 'USER_DISABLED', body.user_id, {});
      return json({ ok: true });
    }

    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
