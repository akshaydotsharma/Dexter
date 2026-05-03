import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  CheckSquare,
  ChevronRight,
  FileText,
  Filter as FilterIcon,
  Folder,
  Inbox,
  List as ListIcon,
  RotateCw,
} from 'lucide-react';
import Card from '../components/Card';
import { getActivity } from '../services/api';

// =============================================================================
// Activity Timeline page (issue #16)
//
// Read-only chronological feed of every note, todo, list, and folder the user
// has created. Renders inside the existing Card primitive at max-w-3xl so it
// matches the rest of the dashboard surfaces. Day-grouped rows, sticky day
// headers, single-select filter chips, infinite scroll via IntersectionObserver,
// deep-link to the owning section with focus + pulse on the destination row.
// =============================================================================

const FILTERS = [
  { id: 'all',    label: 'All',     param: null },
  { id: 'note',   label: 'Notes',   param: 'note' },
  { id: 'todo',   label: 'Todos',   param: 'todo' },
  { id: 'list',   label: 'Lists',   param: 'list' },
  { id: 'folder', label: 'Folders', param: 'folder' },
];

const TYPE_META = {
  note:   { Icon: FileText,    label: 'Note',   varName: '--color-accent-notes',    routeFor: (id) => `/notes?focus=${id}` },
  todo:   { Icon: CheckSquare, label: 'Task',   varName: '--color-accent-tasks',    routeFor: (id) => `/tasks?focus=${id}` },
  list:   { Icon: ListIcon,    label: 'List',   varName: '--color-accent-lists',    routeFor: (id) => `/lists?focus=${id}` },
  folder: { Icon: Folder,      label: 'Folder', varName: '--color-muted',           routeFor: (id) => `/notes?folder=${id}` },
};

// ─── date helpers ────────────────────────────────────────────────────────────

function startOfDay(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  return d;
}

function dayKey(date) {
  // YYYY-MM-DD in local time, used as the bucket key for grouping.
  const d = startOfDay(date);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function formatDayHeader(date) {
  const today = startOfDay(new Date());
  const target = startOfDay(date);
  const diffDays = Math.round((today - target) / (1000 * 60 * 60 * 24));
  if (diffDays === 0) return 'Today';
  if (diffDays === 1) return 'Yesterday';
  if (diffDays > 1 && diffDays < 7) {
    return target.toLocaleDateString(undefined, { weekday: 'long' });
  }
  const sameYear = today.getFullYear() === target.getFullYear();
  if (sameYear) {
    return target.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
  }
  return target.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

function formatRelativeTime(date) {
  const d = new Date(date);
  const now = new Date();
  const diffMs = now - d;
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 1) return 'now';
  if (diffMin < 60) return `${diffMin}m`;
  const diffHour = Math.floor(diffMin / 60);
  if (diffHour < 24) return `${diffHour}h`;
  const today = startOfDay(now);
  const target = startOfDay(d);
  const diffDays = Math.round((today - target) / (1000 * 60 * 60 * 24));
  if (diffDays === 1) return 'Yesterday';
  if (diffDays < 7) return target.toLocaleDateString(undefined, { weekday: 'short' });
  const sameYear = today.getFullYear() === target.getFullYear();
  if (sameYear) {
    return target.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }
  return target.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

function formatAbsolute(date) {
  const d = new Date(date);
  return d.toLocaleString(undefined, {
    weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
}

// ─── small UI atoms ──────────────────────────────────────────────────────────

function FilterChips({ active, onChange }) {
  return (
    <div
      role="group"
      aria-label="Filter by type"
      className="sticky top-[56px] z-10 flex flex-wrap items-center gap-2 px-5 py-3 bg-surface/95 backdrop-blur-sm border-b border-divider"
    >
      {FILTERS.map((f) => {
        const isActive = active === f.id;
        return (
          <button
            key={f.id}
            type="button"
            onClick={() => onChange(f.id)}
            aria-pressed={isActive}
            className={
              'h-8 px-3 rounded-full text-sm transition-colors duration-150 ease-out ' +
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
              (isActive
                ? 'bg-[--color-accent-soft] border border-[--color-accent-ring] text-[--color-accent] font-medium'
                : 'bg-paper-2 border border-border text-ink-soft hover:border-border-strong hover:text-ink')
            }
          >
            {f.label}
          </button>
        );
      })}
    </div>
  );
}

function DayHeader({ label }) {
  return (
    <h2
      className="sticky top-[112px] z-[5] flex items-center gap-2 px-5 h-9 bg-surface/95 backdrop-blur-sm border-b border-divider font-display text-base text-ink tracking-tight uppercase"
      style={{ letterSpacing: '0.04em' }}
    >
      <span
        aria-hidden="true"
        className="inline-block w-1.5 h-1.5 rounded-full"
        style={{ backgroundColor: 'var(--color-accent-activity)' }}
      />
      <span className="text-[13px] text-ink-soft">{label}</span>
    </h2>
  );
}

function ActivityRow({ item, isLast }) {
  const navigate = useNavigate();
  const meta = TYPE_META[item.type] ?? TYPE_META.note;
  const { Icon, label, varName, routeFor } = meta;

  const handleClick = () => {
    navigate(routeFor(item.id));
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleClick();
    }
  };

  // Composed accessible label per the design brief.
  const ariaLabelParts = [`${label} created.`, item.title || 'Untitled'];
  if (item.snippet) ariaLabelParts.push(item.snippet);
  if (item.parent && item.type === 'note') ariaLabelParts.push(`In ${item.parent} folder.`);
  ariaLabelParts.push(formatAbsolute(item.createdAt));
  const ariaLabel = ariaLabelParts.join(' ');

  return (
    <div
      role="link"
      tabIndex={0}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      aria-label={ariaLabel}
      className={
        'group flex items-center gap-3 px-5 py-3 cursor-pointer ' +
        'hover:bg-paper-2 transition-colors duration-150 ease-out ' +
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[--color-accent-ring] ' +
        (isLast ? '' : 'border-b border-divider')
      }
    >
      {/* Tinted icon square: the only colour cue in the row. */}
      <div
        aria-hidden="true"
        className="flex-shrink-0 w-8 h-8 rounded-md flex items-center justify-center"
        style={{
          backgroundColor: `color-mix(in oklab, var(${varName}) 12%, var(--color-paper))`,
        }}
      >
        <Icon
          size={18}
          strokeWidth={1.75}
          style={{ color: `var(${varName})` }}
        />
      </div>

      {/* Title + snippet + parent breadcrumb */}
      <div className="flex-1 min-w-0">
        <div className="text-sm font-medium text-ink truncate">
          {item.title || 'Untitled'}
        </div>
        {item.snippet ? (
          <div className="text-sm text-muted line-clamp-1 mt-0.5">{item.snippet}</div>
        ) : null}
        {item.type === 'note' && item.parent ? (
          <div className="flex items-center gap-1 mt-0.5 text-xs text-muted-soft">
            <Folder size={10} strokeWidth={1.75} aria-hidden="true" />
            <span className="truncate">{item.parent}</span>
          </div>
        ) : null}
      </div>

      {/* Right-aligned time + chevron-on-hover */}
      <div className="flex-shrink-0 flex items-center gap-1">
        <span
          className="text-xs text-muted-soft whitespace-nowrap group-hover:hidden"
          title={formatAbsolute(item.createdAt)}
          aria-label={formatAbsolute(item.createdAt)}
        >
          {formatRelativeTime(item.createdAt)}
        </span>
        <ChevronRight
          size={16}
          strokeWidth={1.75}
          className="hidden group-hover:block text-muted-soft"
          aria-hidden="true"
        />
      </div>
    </div>
  );
}

// ─── skeleton bones ──────────────────────────────────────────────────────────

function PulseBone({ className = '', style = {} }) {
  return (
    <div
      aria-hidden="true"
      className={`bg-paper-2 rounded-sm activity-skeleton-pulse ${className}`}
      style={style}
    />
  );
}

function RowSkeleton({ isLast }) {
  return (
    <div className={`flex items-center gap-3 px-5 py-3 ${isLast ? '' : 'border-b border-divider'}`}>
      <PulseBone className="flex-shrink-0 w-8 h-8 rounded-md" />
      <div className="flex-1 min-w-0 space-y-1.5">
        <PulseBone className="h-3 rounded-sm" style={{ width: '60%' }} />
        <PulseBone className="h-2.5 rounded-sm" style={{ width: '90%' }} />
      </div>
      <PulseBone className="flex-shrink-0 w-8 h-3" />
    </div>
  );
}

function FirstLoadSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading activity">
      {[0, 1, 2].map((groupIdx) => (
        <div key={groupIdx} className={groupIdx === 0 ? '' : 'mt-6'}>
          <div className="flex items-center gap-2 px-5 h-9 border-b border-divider">
            <PulseBone className="w-1.5 h-1.5 rounded-full" />
            <PulseBone className="h-3" style={{ width: 80 }} />
          </div>
          {[0, 1, 2, 3].map((rowIdx) => (
            <RowSkeleton key={rowIdx} isLast={rowIdx === 3} />
          ))}
        </div>
      ))}
    </div>
  );
}

function NextPageSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading more">
      <RowSkeleton isLast={false} />
      <RowSkeleton isLast />
    </div>
  );
}

// ─── empty state ─────────────────────────────────────────────────────────────

function EmptyState({ filterId }) {
  if (filterId === 'all') {
    return (
      <div className="flex flex-col items-center text-center py-20 px-5">
        <Inbox size={28} className="text-muted mb-3" strokeWidth={1.5} aria-hidden="true" />
        <div className="text-base text-ink-soft">Nothing here yet.</div>
        <div className="text-sm text-muted mt-1 max-w-xs">
          Notes, todos, lists, and folders you create will show up here.
        </div>
      </div>
    );
  }
  const filter = FILTERS.find((f) => f.id === filterId);
  const typeLabel = filter ? filter.label.toLowerCase() : 'items';
  return (
    <div className="flex flex-col items-center text-center py-20 px-5">
      <FilterIcon size={28} className="text-muted mb-3" strokeWidth={1.5} aria-hidden="true" />
      <div className="text-base text-ink-soft">No {typeLabel} here yet.</div>
      <div className="text-sm text-muted mt-1">Switch to All to see everything.</div>
    </div>
  );
}

// ─── main page ───────────────────────────────────────────────────────────────

export default function ActivityPage() {
  const [filterId, setFilterId] = useState('all');
  const [items, setItems] = useState([]);
  const [cursor, setCursor] = useState(null);
  const [hasMore, setHasMore] = useState(false);
  const [isFirstLoad, setIsFirstLoad] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState(null);
  const [refreshTick, setRefreshTick] = useState(0);

  const sentinelRef = useRef(null);
  // Guard against stale-filter races: if the user flips the filter mid-fetch,
  // any still-in-flight response should be ignored when it eventually arrives.
  const requestIdRef = useRef(0);

  // Group items by local day. Memoised so we don't re-bucket on every render.
  const groups = useMemo(() => {
    const map = new Map();
    for (const item of items) {
      const key = dayKey(item.createdAt);
      if (!map.has(key)) {
        map.set(key, { key, date: new Date(item.createdAt), items: [] });
      }
      map.get(key).items.push(item);
    }
    // Map iteration preserves insertion order, which mirrors server order
    // (newest first), so we don't need to re-sort.
    return Array.from(map.values());
  }, [items]);

  // ── fetch first page (or refetch on filter / refresh) ──────────────────────
  const loadFirst = useCallback(async (selectedFilterId) => {
    const myRequestId = ++requestIdRef.current;
    setIsFirstLoad(true);
    setError(null);
    setItems([]);
    setCursor(null);
    setHasMore(false);

    const filter = FILTERS.find((f) => f.id === selectedFilterId);
    try {
      const { data } = await getActivity({ type: filter?.param ?? null });
      if (myRequestId !== requestIdRef.current) return; // stale response
      const nextItems = Array.isArray(data?.items) ? data.items : [];
      setItems(nextItems);
      setCursor(data?.nextCursor ?? null);
      setHasMore(Boolean(data?.nextCursor));
    } catch (err) {
      if (myRequestId !== requestIdRef.current) return;
      setError(err?.message || 'Failed to load activity.');
    } finally {
      if (myRequestId === requestIdRef.current) {
        setIsFirstLoad(false);
      }
    }
  }, []);

  // ── fetch next page ────────────────────────────────────────────────────────
  const loadMore = useCallback(async () => {
    if (!cursor || isLoadingMore || isFirstLoad) return;
    const myRequestId = requestIdRef.current; // no bump: appending under same filter
    setIsLoadingMore(true);
    setError(null);
    const filter = FILTERS.find((f) => f.id === filterId);
    try {
      const { data } = await getActivity({ cursor, type: filter?.param ?? null });
      if (myRequestId !== requestIdRef.current) return; // filter changed mid-flight
      const nextItems = Array.isArray(data?.items) ? data.items : [];
      setItems((prev) => [...prev, ...nextItems]);
      setCursor(data?.nextCursor ?? null);
      setHasMore(Boolean(data?.nextCursor));
    } catch (err) {
      if (myRequestId !== requestIdRef.current) return;
      setError(err?.message || 'Failed to load more.');
    } finally {
      if (myRequestId === requestIdRef.current) {
        setIsLoadingMore(false);
      }
    }
  }, [cursor, filterId, isLoadingMore, isFirstLoad]);

  // Trigger first-page fetch on mount + on filter change + on manual refresh.
  useEffect(() => {
    loadFirst(filterId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filterId, refreshTick]);

  // IntersectionObserver on the sentinel: fires loadMore when within 600px
  // of the viewport bottom. Only attached when there's more to load.
  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !hasMore || isFirstLoad) return undefined;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            loadMore();
            break;
          }
        }
      },
      { rootMargin: '600px 0px' }
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasMore, isFirstLoad, loadMore, items.length]);

  const handleRefresh = () => {
    setRefreshTick((t) => t + 1);
  };

  const isEmpty = !isFirstLoad && items.length === 0 && !error;

  return (
    <>
      <style>{`
        @keyframes activity-skeleton {
          0%   { opacity: 0.4; }
          50%  { opacity: 0.7; }
          100% { opacity: 0.4; }
        }
        .activity-skeleton-pulse {
          animation: activity-skeleton 1.4s ease-in-out infinite;
        }
        @media (prefers-reduced-motion: reduce) {
          .activity-skeleton-pulse { animation: none; opacity: 0.55; }
        }
      `}</style>

      <main
        aria-labelledby="activity-heading"
        className="px-6 md:px-10 py-8 max-w-3xl mx-auto w-full"
      >
        {/* Page header: matches PageTitle vibe but adds a refresh control. */}
        <header className="flex items-start justify-between gap-4 mb-6">
          <div>
            <h1
              id="activity-heading"
              className="font-display text-3xl text-ink leading-tight tracking-tight"
              style={{ letterSpacing: '-0.01em' }}
            >
              Activity
            </h1>
            <span
              aria-hidden="true"
              className="block h-[2px] w-8 bg-[--color-accent] mt-2"
            />
            <p className="mt-3 text-sm text-muted leading-[1.55]">
              Everything you have captured, newest first.
            </p>
          </div>

          <button
            type="button"
            onClick={handleRefresh}
            disabled={isFirstLoad}
            aria-label="Refresh activity"
            title="Refresh"
            className={
              'flex-shrink-0 w-9 h-9 rounded-lg flex items-center justify-center ' +
              'text-muted hover:text-ink hover:bg-paper-2 transition-colors duration-150 ease-out ' +
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
              'disabled:opacity-50 disabled:cursor-not-allowed'
            }
          >
            <RotateCw
              size={18}
              strokeWidth={1.75}
              className={isFirstLoad ? 'animate-spin' : ''}
              aria-hidden="true"
            />
          </button>
        </header>

        <Card padding="p-0" className="overflow-hidden">
          <FilterChips active={filterId} onChange={setFilterId} />

          {isFirstLoad ? (
            <FirstLoadSkeleton />
          ) : isEmpty ? (
            <EmptyState filterId={filterId} />
          ) : (
            <div>
              {groups.map((group, gi) => (
                <section key={group.key} className={gi === 0 ? '' : 'mt-6'}>
                  <DayHeader label={formatDayHeader(group.date)} />
                  <div>
                    {group.items.map((item, idx) => (
                      <ActivityRow
                        key={`${item.type}-${item.id}`}
                        item={item}
                        isLast={idx === group.items.length - 1}
                      />
                    ))}
                  </div>
                </section>
              ))}

              {/* Subsequent-page skeleton + sentinel */}
              {isLoadingMore ? <NextPageSkeleton /> : null}

              {error && !isFirstLoad ? (
                <button
                  type="button"
                  onClick={loadMore}
                  className="w-full text-center py-4 text-sm text-danger hover:bg-paper-2 transition-colors"
                >
                  Couldn't load more. Tap to retry.
                </button>
              ) : null}

              {hasMore ? (
                <div ref={sentinelRef} aria-hidden="true" className="h-px" />
              ) : null}
            </div>
          )}
        </Card>
      </main>
    </>
  );
}
