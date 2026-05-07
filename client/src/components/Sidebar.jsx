import { useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import {
  CalendarDays,
  CheckSquare,
  FileText,
  History,
  LayoutDashboard,
  List as ListIcon,
  MessageSquare,
  Settings,
  Sparkles,
  X,
} from 'lucide-react';
import { usePreferences } from '../contexts/preferences-context';

/**
 * v2 Sidebar — collapsed at 64px, expands on hover to 248px (200ms).
 * Mobile = drawer (sheet) triggered by the TopBar hamburger.
 * Active row gets a 3px [--color-accent] left rail + bg-paper-2 fill.
 * The accent rail is the only place per-route color shows up here.
 */

const ITEMS = [
  { type: 'item', to: '/today', label: 'Today', icon: CalendarDays },
  { type: 'item', to: '/chat', label: 'Chat', icon: MessageSquare },
  { type: 'divider' },
  { type: 'item', to: '/tasks', label: 'Tasks', icon: CheckSquare },
  { type: 'item', to: '/notes', label: 'Notes', icon: FileText },
  { type: 'item', to: '/lists', label: 'Lists', icon: ListIcon },
  { type: 'divider' },
  { type: 'item', to: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { type: 'item', to: '/activity', label: 'Activity', icon: History },
  { type: 'divider' },
  { type: 'item', to: '/settings', label: 'Settings', icon: Settings },
];

function NavItem(props) {
  const { to, label, expanded, onNavigate } = props;
  const Icon = props.Icon;
  const [hovered, setHovered] = useState(false);
  const location = useLocation();
  // Active match: prefix-based so /tasks/42 still highlights /tasks.
  const isActive =
    location.pathname === to || location.pathname.startsWith(`${to}/`);

  return (
    <li>
      <NavLink
        to={to}
        onClick={onNavigate}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        aria-current={isActive ? 'page' : undefined}
        className={({ isActive: navActive }) => {
          const active = isActive || navActive;
          return (
            'group relative flex items-center gap-3 h-10 px-3 rounded-lg ' +
            'transition-colors duration-150 ease-out ' +
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
            (active
              ? 'bg-paper-2 text-ink before:absolute before:left-0 before:top-1.5 before:bottom-1.5 before:w-[3px] before:bg-[--color-accent] before:rounded-r-full'
              : 'text-muted hover:text-ink hover:bg-paper-2')
          );
        }}
      >
        <Icon size={20} strokeWidth={1.75} aria-hidden="true" className="flex-shrink-0" />
        <span
          className={
            'whitespace-nowrap text-sm font-medium transition-opacity duration-200 ease-out ' +
            (expanded ? 'opacity-100' : 'opacity-0 pointer-events-none')
          }
        >
          {label}
        </span>

        {/* Tooltip when collapsed (desktop only). 500ms delay via CSS group state. */}
        {!expanded && hovered ? (
          <span
            role="tooltip"
            className="hidden md:block absolute left-full top-1/2 -translate-y-1/2 ml-3 px-2 py-1 rounded text-xs font-mono uppercase tracking-wider bg-ink text-paper whitespace-nowrap pointer-events-none z-50"
          >
            {label}
          </span>
        ) : null}
      </NavLink>
    </li>
  );
}

function SidebarBody({ expanded, onNavigate, wordmark }) {
  return (
    <div className="h-full flex flex-col bg-surface">
      {/* Wordmark + logo tile */}
      <div className="px-3 py-4 flex items-center gap-3">
        <span
          aria-hidden="true"
          className="w-8 h-8 rounded-lg bg-ink text-paper flex items-center justify-center flex-shrink-0"
        >
          <Sparkles size={18} strokeWidth={1.75} />
        </span>
        <span
          className={
            'font-display text-xl text-ink tracking-tight whitespace-nowrap transition-opacity duration-200 ease-out ' +
            (expanded ? 'opacity-100' : 'opacity-0 pointer-events-none')
          }
        >
          {wordmark}
        </span>
      </div>

      <nav className="flex-1 px-2 overflow-y-auto" aria-label="Primary">
        <ul className="space-y-0.5">
          {ITEMS.map((item, idx) => {
            if (item.type === 'divider') {
              return (
                <li key={`div-${idx}`} aria-hidden="true">
                  <div className="border-t border-divider my-2 mx-2" />
                </li>
              );
            }
            return (
              <NavItem
                key={item.to}
                to={item.to}
                label={item.label}
                Icon={item.icon}
                expanded={expanded}
                onNavigate={onNavigate}
              />
            );
          })}
        </ul>
      </nav>

      {/* Footer: profile pip placeholder */}
      <div className="px-2 py-3 border-t border-divider">
        <div
          aria-label="Profile"
          className={
            'flex items-center gap-2 h-9 px-2 rounded-lg overflow-hidden ' +
            (expanded ? 'opacity-100' : 'opacity-0 pointer-events-none')
          }
        >
          <span className="w-7 h-7 rounded-full bg-paper-2 border border-border flex items-center justify-center text-[11px] font-medium text-ink-soft">
            AS
          </span>
          <span className="text-xs text-muted truncate">Akshay</span>
        </div>
      </div>
    </div>
  );
}

export default function Sidebar({ isMobileOpen, setIsMobileOpen }) {
  const { preferences } = usePreferences();
  const wordmark = preferences.wordmark || 'Dashy';
  const [hovered, setHovered] = useState(false);

  return (
    <>
      {/* Mobile drawer */}
      <div
        className={
          'md:hidden fixed inset-0 z-50 transition-opacity duration-200 ease-out ' +
          (isMobileOpen ? 'opacity-100 pointer-events-auto' : 'opacity-0 pointer-events-none')
        }
        aria-hidden={!isMobileOpen}
      >
        <div
          className="absolute inset-0 bg-ink/40"
          onClick={() => setIsMobileOpen(false)}
        />
        <aside
          className={
            'absolute top-0 left-0 h-full w-[80vw] max-w-[280px] bg-surface border-r border-border shadow-md transform transition-transform duration-200 ease-out ' +
            (isMobileOpen ? 'translate-x-0' : '-translate-x-full')
          }
          aria-label="Navigation"
        >
          <button
            type="button"
            onClick={() => setIsMobileOpen(false)}
            className="absolute top-3 right-3 p-2 text-ink-soft hover:bg-paper-2 rounded-lg z-10"
            aria-label="Close navigation"
          >
            <X size={20} strokeWidth={1.75} />
          </button>
          <SidebarBody
            expanded={true}
            wordmark={wordmark}
            onNavigate={() => setIsMobileOpen(false)}
          />
        </aside>
      </div>

      {/* Desktop sidebar — collapsed-by-default rail that expands on hover */}
      <div
        className="hidden md:block flex-shrink-0 h-screen sticky top-0 z-40"
        style={{ width: 64 }}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
      >
        <aside
          className="h-full border-r border-divider bg-surface overflow-hidden transition-[width] duration-200 ease-out"
          style={{ width: hovered ? 248 : 64 }}
          aria-label="Primary navigation"
        >
          <SidebarBody expanded={hovered} wordmark={wordmark} />
        </aside>
      </div>
    </>
  );
}
