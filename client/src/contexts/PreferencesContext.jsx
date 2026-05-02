import { useCallback, useEffect, useMemo, useState } from 'react';
import { getConfig } from '../services/api';
import api from '../services/api';
import { DEFAULT_PREFERENCES, PreferencesContext } from './preferences-context';

/**
 * v2 PreferencesProvider — single source of truth for user-level chrome
 * preferences (theme, default landing view, density, sidebar default,
 * wordmark text). The actual server endpoint is being added by the
 * backend agent; until it lands, PATCHes are tolerated 404s and the
 * preferences remain in local state. Theme is mirrored to localStorage
 * so the inline FOUC script in index.html can read it.
 *
 * The context object, hook, and defaults live in
 * ./preferences-context.js so react-refresh can fast-refresh this
 * component cleanly.
 */

function readMirroredTheme() {
  try {
    const v = localStorage.getItem('theme');
    if (v === 'light' || v === 'dark' || v === 'system') return v;
  } catch {
    /* private mode / no localStorage — no-op */
  }
  return null;
}

function writeMirroredTheme(theme) {
  try {
    localStorage.setItem('theme', theme);
  } catch {
    /* no-op */
  }
}

export function PreferencesProvider({ children }) {
  const initialTheme = readMirroredTheme();
  const [preferences, setPreferences] = useState({
    ...DEFAULT_PREFERENCES,
    ...(initialTheme ? { theme: initialTheme } : {}),
  });
  const [ready, setReady] = useState(false);

  // Load server config once on mount.
  useEffect(() => {
    let cancelled = false;
    getConfig()
      .then((res) => {
        if (cancelled) return;
        const layout = res.data?.layout_preference || {};
        const serverPrefs = layout.preferences || {};
        setPreferences(() => ({
          ...DEFAULT_PREFERENCES,
          ...serverPrefs,
          // localStorage-mirrored theme wins over server-stored theme on
          // initial paint (FOUC alignment); server can correct on next mount.
          ...(initialTheme ? { theme: initialTheme } : {}),
        }));
      })
      .catch((err) => {
        // Network failure is fine; we use defaults.
        console.warn('[PreferencesContext] config load failed, using defaults', err?.message);
      })
      .finally(() => {
        if (!cancelled) setReady(true);
      });
    return () => {
      cancelled = true;
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const updatePreferences = useCallback(async (partial) => {
    setPreferences((current) => {
      const next = { ...current, ...partial };
      if (Object.prototype.hasOwnProperty.call(partial, 'theme')) {
        writeMirroredTheme(next.theme);
      }
      return next;
    });

    // TODO: wire when backend lands /api/dashboard/config/preferences.
    // For now, attempt the PATCH and silently swallow 404s so the UI
    // remains functional in development before the backend is ready.
    try {
      await api.patch('/dashboard/config/preferences', partial);
    } catch (err) {
      const status = err?.response?.status;
      if (status && status !== 404 && status !== 405) {
        console.warn('[PreferencesContext] preference save failed', status);
      }
    }
  }, []);

  const value = useMemo(
    () => ({ preferences, updatePreferences, ready }),
    [preferences, updatePreferences, ready]
  );

  return <PreferencesContext.Provider value={value}>{children}</PreferencesContext.Provider>;
}
