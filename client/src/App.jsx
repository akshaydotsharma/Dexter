import { useState, useEffect, useRef } from 'react';
import DashboardGrid from './components/DashboardGrid';
import { getConfig, getStats } from './services/api';
import TodoWidget from './components/TodoWidget';
import TodoWidgetV2 from './components/TodoWidgetV2';
import NotesWidget from './components/NotesWidget';
import ChatPopover from './components/ChatPopover';
import ListsWidget from './components/ListsWidget';
import Sidebar from './components/Sidebar';
import LanguageInputPage from './pages/LanguageInputPage';
import StatsCard from './components/StatsCard';

function App() {
  const [config, setConfig] = useState(null);
  const [loading, setLoading] = useState(true);
  const [currentView, setCurrentView] = useState('chatbot');
  const [isChatPopoverOpen, setIsChatPopoverOpen] = useState(false);
  const [stats, setStats] = useState({
    todos: { total: 0, trend: 0 },
    notes: { total: 0, trend: 0 },
    lists: { total: 0, trend: 0 }
  });
  const [rightColumnHeight, setRightColumnHeight] = useState(null);
  const rightColumnRef = useRef(null);

  useEffect(() => {
    getConfig()
      .then(res => {
        setConfig(res.data);
        setLoading(false);
      })
      .catch(err => {
        console.error("Failed to load config from server, using default.", err);
        setConfig({ layout_preference: { widgets: ["todos", "notes", "lists"] } });
        setLoading(false);
      });
  }, []);

  // Fetch stats when viewing dashboard
  useEffect(() => {
    if (currentView === 'dashboard') {
      getStats()
        .then(res => setStats(res.data))
        .catch(err => console.error('Error fetching stats:', err));
    }
  }, [currentView]);

  // Observe right column height and sync to Notes widget
  useEffect(() => {
    if (currentView !== 'dashboard' || !rightColumnRef.current) return;

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setRightColumnHeight(entry.contentRect.height);
      }
    });

    observer.observe(rightColumnRef.current);
    return () => observer.disconnect();
  }, [currentView]);

  if (loading) return <div className="min-h-screen flex items-center justify-center text-indigo-600 bg-slate-50">Loading...</div>;

  const visibleWidgets = config?.layout_preference?.widgets || [];

  const renderContent = () => {
    switch (currentView) {
      case 'chatbot':
        return (
          <div className="max-w-4xl mx-auto w-full h-[calc(100vh-8rem)]">
            <LanguageInputPage />
          </div>
        );
      case 'todos':
        return (
          <div className="max-w-3xl mx-auto w-full h-[calc(100vh-10rem)]">
            <TodoWidget fullHeight />
          </div>
        );
      case 'todos-v2':
        return (
          <div className="max-w-3xl mx-auto w-full">
            <TodoWidgetV2 />
          </div>
        );
      case 'notes':
        return (
          <div className="max-w-3xl mx-auto w-full h-[calc(100vh-10rem)]">
            <NotesWidget fullHeight />
          </div>
        );
      case 'lists':
        return (
          <div className="max-w-3xl mx-auto w-full h-[calc(100vh-10rem)]">
            <ListsWidget fullHeight />
          </div>
        );
      case 'dashboard':
      default:
        return (
          <div className="container mx-auto px-4 max-w-7xl">
            {/* Stats Tiles Section */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
              <StatsCard
                title="Total Tasks"
                value={stats.todos.total}
                trend={stats.todos.trend}
              />
              <StatsCard
                title="Total Notes"
                value={stats.notes.total}
                trend={stats.notes.trend}
              />
              <StatsCard
                title="Total Lists"
                value={stats.lists.total}
                trend={stats.lists.trend}
              />
            </div>

            {/* Dashboard Grid - Custom Layout */}
            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 items-start">
              {/* Notes Widget - Spans 2 columns, height synced to right column */}
              {visibleWidgets.includes('notes') && (
                <div className="lg:col-span-2">
                  <NotesWidget maxHeightPx={rightColumnHeight} />
                </div>
              )}
              {/* Right column - Todos and Lists stacked */}
              <div ref={rightColumnRef} className="flex flex-col gap-6">
                {visibleWidgets.includes('todos') && (
                  <TodoWidget />
                )}
                {visibleWidgets.includes('lists') && (
                  <ListsWidget />
                )}
              </div>
            </div>
          </div>
        );
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 flex overflow-hidden">
      <Sidebar currentView={currentView} setCurrentView={setCurrentView} />

      <main className="flex-1 relative overflow-auto h-screen">
        <div className="p-8">
          {currentView !== 'chatbot' && (
            <header className="mb-8">
              <h1 className="text-2xl font-bold text-slate-800 capitalize">
                {currentView === 'dashboard' ? 'Personal Dashboard' :
                 currentView === 'todos' ? 'Tasks' :
                 currentView === 'todos-v2' ? 'Tasks V2' : currentView}
              </h1>
              <p className="text-slate-500">
                {currentView === 'dashboard'
                  ? 'Your personal organization snapshot'
                  : currentView === 'todos' || currentView === 'todos-v2'
                  ? 'Manage your tasks here.'
                  : `Manage your ${currentView} here.`}
              </p>
            </header>
          )}

          {renderContent()}
        </div>

        {/* Floating Chat Button */}
        {currentView !== 'chatbot' && !isChatPopoverOpen && (
          <button
            onClick={() => setIsChatPopoverOpen(true)}
            className="fixed bottom-8 right-8 p-4 bg-indigo-600 hover:bg-indigo-700 text-white rounded-full shadow-lg shadow-indigo-500/30 transition-all duration-300 hover:scale-110 active:scale-95 group z-50"
            title="Open AI Assistant"
          >
            <div className="absolute inset-0 rounded-full bg-white/20 animate-ping opacity-0 group-hover:opacity-30" />
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
              <path d="M8 10h.01" />
              <path d="M12 10h.01" />
              <path d="M16 10h.01" />
            </svg>
          </button>
        )}

        {/* Chat Popover */}
        <ChatPopover
          isOpen={isChatPopoverOpen}
          onClose={() => setIsChatPopoverOpen(false)}
        />
      </main>
    </div>
  );
}

export default App;
