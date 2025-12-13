import { LayoutDashboard, CheckSquare, FileText, List as ListIcon, Settings, LogOut, Bot } from 'lucide-react';

export default function Sidebar({ currentView, setCurrentView }) {
    const menuItems = [
        { id: 'chatbot', icon: Bot, label: 'AI Assistant' },
        { id: 'dashboard', icon: LayoutDashboard, label: 'Dashboard' },
        { id: 'todos', icon: CheckSquare, label: 'Tasks' },
        { id: 'todos-v2', icon: CheckSquare, label: 'Tasks V2' },
        { id: 'notes', icon: FileText, label: 'Notes' },
        { id: 'lists', icon: ListIcon, label: 'Lists' },
    ];

    return (
        // Outer placeholder div that stays in the layout flow
        <div className="w-20 shrink-0 h-screen relative z-50">
            {/* Inner sidebar that expands absolutely over content */}
            <div className="absolute top-0 left-0 h-full w-20 hover:w-64 bg-white border-r border-slate-200 flex flex-col shadow-sm transition-all duration-300 group overflow-hidden">
                <div className="p-6">
                    <div className="flex items-center gap-3">
                        <div className="w-8 h-8 rounded-lg bg-indigo-600 flex items-center justify-center shrink-0">
                            <LayoutDashboard className="text-white w-5 h-5" />
                        </div>
                        <span className="text-xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-indigo-600 to-indigo-800 opacity-0 group-hover:opacity-100 transition-opacity duration-300 whitespace-nowrap">
                            Dashy
                        </span>
                    </div>
                </div>

                <nav className="flex-1 px-4 space-y-1">
                    {menuItems.map((item) => {
                        const Icon = item.icon;
                        const isActive = currentView === item.id;

                        return (
                            <button
                                key={item.id}
                                onClick={() => setCurrentView(item.id)}
                                className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-lg transition-all duration-200 cursor-pointer ${isActive
                                    ? 'bg-indigo-50 text-indigo-700 font-medium'
                                    : 'text-slate-600 hover:bg-slate-50 hover:text-slate-900'
                                    }`}
                            >
                                <Icon
                                    size={20}
                                    className={`transition-colors shrink-0 ${isActive ? 'text-indigo-600' : 'text-slate-400 group-hover:text-slate-600'
                                        }`}
                                />
                                <span className="opacity-0 group-hover:opacity-100 transition-opacity duration-300 whitespace-nowrap delay-75">
                                    {item.label}
                                </span>
                            </button>
                        );
                    })}
                </nav>

                <div className="p-4 border-t border-slate-100">
                    <button className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-slate-600 hover:bg-slate-50 hover:text-slate-900 transition-all duration-200 cursor-pointer">
                        <Settings size={20} className="text-slate-400 shrink-0" />
                        <span className="opacity-0 group-hover:opacity-100 transition-opacity duration-300 whitespace-nowrap delay-75">
                            Settings
                        </span>
                    </button>
                    <button className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-slate-600 hover:bg-rose-50 hover:text-rose-600 transition-all duration-200 mt-1 cursor-pointer">
                        <LogOut size={20} className="text-slate-400 hover:text-rose-500 shrink-0" />
                        <span className="opacity-0 group-hover:opacity-100 transition-opacity duration-300 whitespace-nowrap delay-75">
                            Logout
                        </span>
                    </button>

                    <div className="mt-6 flex items-center gap-3 px-3 overflow-hidden">
                        <div className="w-8 h-8 rounded-full bg-slate-200 shrink-0" />
                        <div className="min-w-0 opacity-0 group-hover:opacity-100 transition-opacity duration-300 delay-75">
                            <p className="text-sm font-medium text-slate-900 truncate">Akshay Sharma</p>
                            <p className="text-xs text-slate-500 truncate">akshay@example.com</p>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}
