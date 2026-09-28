import React, { useEffect, useState, lazy, Suspense } from 'react';
import { supabase, DEMO } from './lib/supabase.js';
import { store } from './lib/store.js';
import Login from './Login.jsx';
import PromoterApp from './promoter/PromoterApp.jsx';

const StaffApp = lazy(() => import('./staff/StaffApp.jsx'));

async function fetchProfile(uid) {
  const { data, error } = await supabase.from('app_users').select('*').eq('id', uid).maybeSingle();
  if (error) throw error;
  return data;
}

export default function App() {
  return (
    <>
      {DEMO && <div className="demo-ribbon">DEMO MODE · sample data on this device only</div>}
      <AppInner />
    </>
  );
}

function AppInner() {
  const [state, setState] = useState({ loading: true, session: null, profile: null, error: null });

  async function resolve(session) {
    if (!session) { setState({ loading: false, session: null, profile: null }); return; }
    const cacheKey = `rio.profile.${session.user.id}`;
    try {
      const profile = await fetchProfile(session.user.id);
      if (!profile || !profile.is_active) {
        await supabase.auth.signOut();
        setState({ loading: false, session: null, profile: null, error: profile ? 'Your account has been disabled.' : 'No app profile for this login.' });
        return;
      }
      store.set(cacheKey, profile);
      setState({ loading: false, session, profile });
    } catch {
      // offline: use cached profile so the promoter is not locked out by weak signal
      const cached = store.get(cacheKey);
      setState({ loading: false, session, profile: cached, error: cached ? null : 'Cannot reach server.' });
    }
  }

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => resolve(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT') setState({ loading: false, session: null, profile: null });
      if (event === 'SIGNED_IN') resolve(session);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  if (state.loading) return <div className="boot"><div className="boot-wheel" /><p>RIO SPIN & WIN</p></div>;
  if (!state.session || !state.profile) return <Login key={state.error || "login"} error={state.error} />;

  const logout = async () => {
    await supabase.auth.signOut();
  };

  if (state.profile.role === 'promoter') return <PromoterApp profile={state.profile} onLogout={logout} />;
  return (
    <Suspense fallback={<div className="boot"><p>Loading dashboard…</p></div>}>
      <StaffApp profile={state.profile} onLogout={logout} />
    </Suspense>
  );
}
