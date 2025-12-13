import { useEffect, useState } from 'react';
import DashboardGrid from './DashboardGrid';
import { getConfig } from '../services/api';
import TodoWidget from './TodoWidget';
import NotesWidget from './NotesWidget';
import ListsWidget from './ListsWidget';
import StatsCard from './StatsCard';
import { CheckSquare, FileText, List } from 'lucide-react';

function DashboardView({ view = 'dashboard' }) {
    const [config, setConfig] = useState(null);
    const [loading, setLoading] = useState(true);

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

    if (loading) return <div className="min-h-screen flex items-center justify-center text-indigo-600 bg-slate-50">Loading...</div>;

    const visibleWidgets = config?.layout_preference?.widgets || [];

    const renderContent = () => {
        switch (view) {
            case 'todos':
                return (
                    <div className="max-w-3xl mx-auto w-full h-full flex flex-col">
                        <TodoWidget />
                    </div>
                );
            case 'notes':
                return (
                    <div className="max-w-3xl mx-auto w-full">
                        <NotesWidget />
                    </div>
                );
            case 'lists':
                return (
                    <div className="max-w-3xl mx-auto w-full">
                        <ListsWidget />
                    </div>
                );
            case 'dashboard':
            default:
                return (
                    <div className="container mx-auto px-4 py-8 max-w-7xl h-full flex flex-col overflow-hidden min-h-0">
                        {/* Dashboard Header */}
                        <header className="mb-8">
                            <h1 className="text-3xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-indigo-600 to-indigo-400">
                                Personal Dashboard
                            </h1>
                        </header>

                        {/* Stats Tiles Section */}
                        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
                            <StatsCard
                                title="Total Tasks"
                                value={24}
                                trend={12}
                                icon={CheckSquare}
                            />
                            <StatsCard
                                title="Active Notes"
                                value={12}
                                trend={-5}
                                icon={FileText}
                            />
                            <StatsCard
                                title="Lists Created"
                                value={8}
                                trend={0}
                                icon={List}
                            />
                        </div>

                        {/* Dashboard Grid */}
                        <DashboardGrid>
                            {visibleWidgets.includes('todos') && <TodoWidget />}
                            {visibleWidgets.includes('notes') && <NotesWidget />}
                            {visibleWidgets.includes('lists') && <ListsWidget />}
                        </DashboardGrid>
                    </div>
                );
        }
    };

    return (
        <div className="flex-1 relative overflow-auto">
            {/* Decorative background elements relative to main content area */}
            <div className="absolute top-0 left-0 w-full h-96 bg-linear-to-br from-indigo-50 to-slate-50 -z-10" />
            <div className="absolute top-[-20%] right-[-10%] w-[500px] h-[500px] bg-indigo-200/20 rounded-full blur-[100px] -z-10 pointer-events-none" />

            <div className="p-8">
                {view !== 'dashboard' && (
                    <header className="mb-8">
                        <h1 className="text-2xl font-bold text-slate-800 capitalize">
                            {view}
                        </h1>
                        <p className="text-slate-500">
                            {`Manage your ${view} here.`}
                        </p>
                    </header>
                )}

                {renderContent()}
            </div>
        </div>
    );
}

export default DashboardView;
