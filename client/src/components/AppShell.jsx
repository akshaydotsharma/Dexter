import { useEffect, useMemo, useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import { ThemeProvider, createTheme } from '@mui/material/styles';
import { MessageSquare } from 'lucide-react';
import { usePreferences } from '../contexts/preferences-context';
import { ChatProvider } from '../contexts/ChatContext';
import Sidebar from './Sidebar';
import TopBar from './TopBar';
import ChatPopover from './ChatPopover';
import { getStats } from '../services/api';

const ROUTE_SEGMENTS = ['today', 'chat', 'tasks', 'notes', 'lists', 'dashboard', 'activity', 'settings'];

function deriveRoute(pathname) {
  const seg = pathname.split('/').filter(Boolean)[0];
  return ROUTE_SEGMENTS.includes(seg) ? seg : 'today';
}

function readAccentVar(name) {
  if (typeof window === 'undefined') return '';
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

/**
 * v2 AppShell — the shared layout that all routes mount under.
 *
 * Responsibilities:
 *   1. Stamp <html data-route="..."> for the per-section accent.
 *   2. Stamp <html data-theme="..."> from preferences ('system' = no attr).
 *   3. Stamp <html data-density="..."> (comfortable | compact).
 *   4. Render Sidebar + TopBar + main outlet.
 *   5. Mount the ChatPopover FAB (hidden on /chat and on /today mobile).
 *   6. Wrap children in a thin MUI ThemeProvider so date pickers don't
 *      look out of place on warm paper.
 */
export default function AppShell() {
  const { preferences } = usePreferences();
  const location = useLocation();
  const route = deriveRoute(location.pathname);

  const [isMobileSidebarOpen, setIsMobileSidebarOpen] = useState(false);
  const [isChatPopoverOpen, setIsChatPopoverOpen] = useState(false);

  // Stamp data-route on <html> so [data-route="..."] in CSS picks the accent.
  useEffect(() => {
    document.documentElement.dataset.route = route;
  }, [route]);

  // Stamp data-theme: 'light' | 'dark' explicit, 'system' removes the attr
  // so the prefers-color-scheme media query takes effect.
  useEffect(() => {
    const theme = preferences.theme || 'system';
    if (theme === 'system') {
      delete document.documentElement.dataset.theme;
    } else {
      document.documentElement.dataset.theme = theme;
    }
  }, [preferences.theme]);

  // Stamp data-density.
  useEffect(() => {
    document.documentElement.dataset.density = preferences.density || 'comfortable';
  }, [preferences.density]);

  // Close mobile sidebar on route change. Guarded so we don't trigger
  // an unnecessary render when the sidebar is already closed.
  useEffect(() => {
    setIsMobileSidebarOpen((open) => (open ? false : open));
  }, [location.pathname]);

  // Resolve --color-accent on the current route for MUI primary color.
  // CSS variables aren't available during the initial JS render so we
  // re-read on every route change after paint via useEffect.
  const [muiAccent, setMuiAccent] = useState('#4338CA');
  useEffect(() => {
    // Allow the new data-route to land before reading.
    const id = requestAnimationFrame(() => {
      const v = readAccentVar('--color-accent') || readAccentVar('--color-accent-tasks') || '#4338CA';
      setMuiAccent(v);
    });
    return () => cancelAnimationFrame(id);
  }, [route, preferences.theme]);

  const muiTheme = useMemo(() =>
    createTheme({
      palette: {
        mode: preferences.theme === 'dark' ? 'dark' : 'light',
        primary: { main: muiAccent || '#4338CA' },
      },
      typography: {
        fontFamily:
          'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
      },
    }),
  [muiAccent, preferences.theme]);

  // Visibility rules for the floating chat button:
  // - hide on /chat (the chat IS the surface)
  // - hide on /today on mobile (Today already gives a Chat entry point)
  const isChatRoute = route === 'chat';
  const isTodayMobile = route === 'today';
  const hideFab = isChatRoute; // mobile-only Today hide is handled via Tailwind below.

  return (
    <ChatProvider>
    <ThemeProvider theme={muiTheme}>
      <div className="min-h-screen bg-paper text-ink flex">
        <Sidebar
          isMobileOpen={isMobileSidebarOpen}
          setIsMobileOpen={setIsMobileSidebarOpen}
        />

        <div className="flex-1 min-w-0 flex flex-col h-screen overflow-hidden">
          <TopBar
            onOpenMobileSidebar={() => setIsMobileSidebarOpen(true)}
            onOpenCommandPalette={() => {
              // TODO: wire when Cmd+K palette ships in step 5
            }}
          />

          <main className="flex-1 min-h-0 overflow-auto">
            <Outlet />
          </main>
        </div>

        {!hideFab ? (
          <button
            type="button"
            onClick={() => setIsChatPopoverOpen(true)}
            aria-label="Open AI Assistant"
            title="Open AI Assistant"
            className={
              'fixed bottom-6 right-6 z-40 w-12 h-12 rounded-full bg-ink text-paper hover:bg-ink-soft ' +
              'shadow-md hover:shadow-lg transition-shadow duration-200 ease-out ' +
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
              'flex items-center justify-center ' +
              // hide on mobile when on /today
              (isTodayMobile ? 'hidden md:flex' : 'flex')
            }
          >
            <MessageSquare size={20} strokeWidth={1.75} aria-hidden="true" />
          </button>
        ) : null}

        <ChatPopover
          isOpen={isChatPopoverOpen}
          onClose={() => setIsChatPopoverOpen(false)}
          onDraftConfirmed={() => {
            // Stats refresh is best-effort; widget refreshes will be wired
            // through the registry in step 7.
            getStats().catch(() => { /* swallow */ });
          }}
        />
      </div>
    </ThemeProvider>
    </ChatProvider>
  );
}
