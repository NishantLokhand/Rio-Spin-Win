const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const GUPSHUP_URL = 'https://api.gupshup.io/wa/api/v1/template/msg';
const thresholds = {
  '7pm': { threshold: 5, deadline: '7:00 PM' },
  '8pm': { threshold: 10, deadline: '8:00 PM' },
  '9pm': { threshold: 15, deadline: '9:00 PM' },
} as const;

const response = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return response({ error: 'Method not allowed' }, 405);

  const required = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'GUPSHUP_API_KEY', 'GUPSHUP_APP_NAME', 'GUPSHUP_SOURCE_NUMBER', 'GUPSHUP_TEMPLATE_ID'];
  const missing = required.filter((name) => !Deno.env.get(name));
  if (missing.length) return response({ error: 'Missing function secrets', missing }, 503);

  const body = await req.json().catch(() => ({}));
  const stage = body.stage as keyof typeof thresholds | undefined;
  if (!stage || !thresholds[stage]) return response({ error: 'stage must be 7pm, 8pm, or 9pm' }, 400);
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date());
  const { data: users, error: usersError } = await db.from('app_users')
    .select('id, full_name, mobile')
    .eq('role', 'promoter').eq('is_active', true).eq('whatsapp_alerts_enabled', true)
    .not('mobile', 'is', null).is('whatsapp_opted_out_at', null);
  if (usersError) return response({ error: usersError.message }, 500);
  const userIds = (users ?? []).map((u) => u.id);
  const { data: spins, error: spinsError } = userIds.length
    ? await db.from('spins').select('promoter_id').eq('biz_date', today).in('promoter_id', userIds)
    : { data: [], error: null };
  if (spinsError) return response({ error: spinsError.message }, 500);
  const counts = new Map<string, number>();
  for (const spin of spins ?? []) counts.set(spin.promoter_id, (counts.get(spin.promoter_id) ?? 0) + 1);
  const { data: sent, error: sentError } = await db.from('whatsapp_reminder_log').select('user_id').eq('reminder_date', today).eq('reminder_stage', stage);
  if (sentError) return response({ error: sentError.message }, 500);
  const alreadySent = new Set((sent ?? []).map((row) => row.user_id));
  const result = { stage, date: today, considered: users?.length ?? 0, sent: 0, skipped: 0, failed: 0 };
  for (const user of users ?? []) {
    const spinCount = counts.get(user.id) ?? 0;
    if (spinCount >= thresholds[stage].threshold || alreadySent.has(user.id)) { result.skipped++; continue; }
    const form = new URLSearchParams({
      channel: 'whatsapp', source: Deno.env.get('GUPSHUP_SOURCE_NUMBER')!, destination: String(user.mobile).replace(/\D/g, ''),
      'src.name': Deno.env.get('GUPSHUP_APP_NAME')!,
      template: JSON.stringify({ id: Deno.env.get('GUPSHUP_TEMPLATE_ID')!, params: [user.full_name, String(spinCount), String(thresholds[stage].threshold), thresholds[stage].deadline] }),
    });
    const api = await fetch(GUPSHUP_URL, { method: 'POST', headers: { apikey: Deno.env.get('GUPSHUP_API_KEY')!, 'Content-Type': 'application/x-www-form-urlencoded' }, body: form });
    const raw = await api.text();
    let parsed: Record<string, unknown> = {}; try { parsed = JSON.parse(raw); } catch { parsed = { raw }; }
    const providerId = String(parsed.messageId ?? parsed.id ?? '');
    const status = api.ok ? String(parsed.status ?? 'submitted') : 'failed';
    await db.from('whatsapp_reminder_log').insert({ user_id: user.id, reminder_date: today, reminder_stage: stage, threshold: thresholds[stage].threshold, spin_count_at_send: spinCount, provider_message_id: providerId || null, status, failure_reason: api.ok ? null : raw });
    if (api.ok) result.sent++; else result.failed++;
  }
  return response({ ok: true, ...result });
});
