import { useEffect, useRef, useState } from 'react';
import { getStats } from '../services/api';
import { usePreferences } from '../contexts/preferences-context';
import StatsCard from '../components/StatsCard';
import TodoWidget from '../components/TodoWidget';
import NotesWidget from '../components/NotesWidget';
import ListsWidget from '../components/ListsWidget';
import PageTitle from '../components/PageTitle';

/**
 * v2 Dashboard page — extracts the bento grid from the legacy App.jsx
 * into its own page. Visual treatment of widgets is unchanged this pass;
 * only the page-title chrome (Calistoga + accent underline) is new.
 */
export default function DashboardPage() {
  const { preferences } = usePreferences();
  const [stats, setStats] = useState({
    todos: { total: 0, trend: 0 },
    notes: { total: 0, trend: 0 },
    lists: { total: 0, trend: 0 },
  });
  const [rightColumnHeight, setRightColumnHeight] = useState(null);
  const rightColumnRef = useRef(null);

  useEffect(() => {
    getStats()
      .then((res) => setStats(res.data))
      .catch((err) => console.error('Error fetching stats:', err));
  }, []);

  useEffect(() => {
    if (!rightColumnRef.current) return;
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setRightColumnHeight(entry.contentRect.height);
      }
    });
    observer.observe(rightColumnRef.current);
    return () => observer.disconnect();
  }, []);

  const visibleWidgets = preferences?.widgets || ['todos', 'notes', 'lists'];

  return (
    <div className="px-6 md:px-10 py-8 max-w-7xl mx-auto w-full">
      <PageTitle eyebrow="Dashboard" subtitle="Everything in view.">
        Dashboard
      </PageTitle>

      <div className="mt-10 grid grid-cols-2 md:grid-cols-3 gap-3 md:gap-6 mb-8">
        <StatsCard title="Total Tasks" value={stats?.todos?.total ?? 0} trend={stats?.todos?.trend ?? 0} />
        <StatsCard title="Total Notes" value={stats?.notes?.total ?? 0} trend={stats?.notes?.trend ?? 0} />
        <StatsCard
          title="Total Lists"
          value={stats?.lists?.total ?? 0}
          trend={stats?.lists?.trend ?? 0}
          className="col-span-2 md:col-span-1"
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 items-start">
        {visibleWidgets.includes('notes') && (
          <div className="lg:col-span-2">
            <NotesWidget maxHeightPx={rightColumnHeight} />
          </div>
        )}
        <div ref={rightColumnRef} className="flex flex-col gap-6">
          {visibleWidgets.includes('todos') && <TodoWidget />}
          {visibleWidgets.includes('lists') && <ListsWidget />}
        </div>
      </div>
    </div>
  );
}
