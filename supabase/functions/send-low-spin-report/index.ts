import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { zipSync } from 'https://esm.sh/fflate@0.8.2';
import { createLowSpinHandler } from '../_shared/lowSpinDelivery.mjs';

const env = Object.fromEntries(['SUPABASE_URL','SUPABASE_SERVICE_ROLE_KEY','LOW_SPIN_CRON_TOKEN','GMAIL_CLIENT_ID','GMAIL_CLIENT_SECRET','GMAIL_REFRESH_TOKEN']
  .map(key=>[key,Deno.env.get(key)||'']));
const db=createClient(env.SUPABASE_URL,env.SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(createLowSpinHandler({ env,db,zipSync,isAdmin:async token=>{
  const {data:{user},error}=await db.auth.getUser(token);if(error||!user)return false;
  const {data}=await db.from('app_users').select('role,is_active').eq('id',user.id).single();
  return data?.role==='admin'&&data?.is_active===true;
}}));
