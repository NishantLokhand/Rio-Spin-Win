import { useEffect, useState } from 'react';

export function useAppUpdate(intervalMs = 5 * 60 * 60 * 1000) {
  const [available, setAvailable] = useState(false);
  useEffect(() => {
    let stopped = false;
    const check = async () => {
      try {
        const res = await fetch(`/version.json?check=${Date.now()}`, { cache: 'no-store' });
        if (!res.ok) return;
        const remote = await res.json();
        if (!stopped && remote?.version && remote.version !== __APP_VERSION__) setAvailable(true);
      } catch { /* offline or a development server without a version file */ }
    };
    check();
    const timer = setInterval(check, intervalMs);
    return () => { stopped = true; clearInterval(timer); };
  }, [intervalMs]);
  return available;
}

export function UpdateNotice({ className = '' }) {
  const available = useAppUpdate();
  if (!available) return null;
  return <div className={`app-update-notice ${className}`} role="status">
    <span>New version available</span>
    <button type="button" onClick={() => window.location.reload()}>Reload</button>
  </div>;
}
