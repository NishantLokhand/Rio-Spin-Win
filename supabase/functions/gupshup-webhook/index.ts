const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

type Json = Record<string, unknown>;

const json = (body: Json, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method === 'GET') return json({ ok: true, service: 'gupshup-webhook' });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const payload = await req.json();
    console.log('Gupshup webhook event', JSON.stringify(payload));
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (url && key) {
      const db = createClient(url, key);
      const messageId = String(payload?.payload?.id ?? payload?.messageId ?? payload?.id ?? '');
      const status = String(payload?.type ?? payload?.status ?? payload?.payload?.type ?? 'received');
      if (messageId) {
        await db.from('whatsapp_reminder_log')
          .update({ status, updated_at: new Date().toISOString(), failure_reason: status === 'failed' ? JSON.stringify(payload) : null })
          .eq('provider_message_id', messageId);
      }
    }
    return json({ ok: true });
  } catch (error) {
    console.error('Invalid Gupshup webhook payload', error);
    return json({ error: 'Invalid JSON payload' }, 400);
  }
});
