import { Menu, Search } from 'lucide-react';
import { useLocation } from 'react-router-dom';
import Kbd from './Kbd';
import ThemeToggle from './ThemeToggle';

const ROUTE_LABELS = {
  today: 'Today',
  chat: 'Chat',
  tasks: 'Tasks',
  notes: 'Notes',
  lists: 'Lists',
  dashboard: 'Dashboard',
  settings: 'Settings',
};

function deriveSection(pathname) {
  const seg = pathname.split('/').filter(Boolean)[0] || 'today';
  return ROUTE_LABELS[seg] ? seg : 'today';
}

/**
 * v2 TopBar — desktop chrome at 56px. Left: mobile hamburger (md-hidden).
 * Center/left: a small Calistoga breadcrumb of the current section.
 * Right: a Cmd+K trigger pill (placeholder onClick — palette ships in
 * step 5), the theme toggle, and a profile pip placeholder.
 */
export default function TopBar({ onOpenMobileSidebar, onOpenCommandPalette }) {
  const location = useLocation();
  const section = deriveSection(location.pathname);
  const label = ROUTE_LABELS[section];

  return (
    <header className="bg-paper border-b border-divider h-14 px-4 md:px-6 flex items-center justify-between flex-shrink-0">
      <div className="flex items-center gap-3 min-w-0">
        <button
          type="button"
          onClick={onOpenMobileSidebar}
          aria-label="Open navigation"
          className="md:hidden inline-flex items-center justify-center w-9 h-9 rounded-lg text-ink-soft hover:bg-paper-2 transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
        >
          <Menu size={20} strokeWidth={1.75} aria-hidden="true" />
        </button>

        <span className="md:hidden font-display text-lg text-ink truncate">{label}</span>
      </div>

      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onOpenCommandPalette}
          aria-label="Open command palette"
          className="hidden lg:inline-flex items-center gap-2 h-9 px-3 rounded-lg bg-paper-2 border border-border text-muted hover:text-ink hover:border-border-strong transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
        >
          <Search size={16} strokeWidth={1.75} aria-hidden="true" />
          <span className="text-sm">Search or run a command</span>
          <span className="flex items-center gap-0.5 ml-2">
            <Kbd>cmd</Kbd>
            <Kbd>K</Kbd>
          </span>
        </button>

        <button
          type="button"
          onClick={onOpenCommandPalette}
          aria-label="Open command palette"
          className="lg:hidden inline-flex items-center justify-center w-9 h-9 rounded-lg text-ink-soft hover:bg-paper-2 transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
        >
          <Search size={18} strokeWidth={1.75} aria-hidden="true" />
        </button>

        <ThemeToggle />

        <div
          aria-label="Profile"
          className="w-9 h-9 rounded-full bg-paper-2 border border-border flex items-center justify-center text-xs font-medium text-ink-soft select-none"
        >
          AS
        </div>
      </div>
    </header>
  );
}
