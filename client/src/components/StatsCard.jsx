import { TrendingUp, TrendingDown } from 'lucide-react';

export default function StatsCard({ title, value, trend, icon: Icon }) {
    const isPositiveTrend = trend && trend > 0;
    const isNegativeTrend = trend && trend < 0;

    return (
        <div className="group relative bg-white/80 backdrop-blur-sm rounded-2xl p-6 shadow-lg border border-indigo-100 hover:shadow-xl hover:border-indigo-200 transition-all duration-300 hover:-translate-y-1">
            {/* Gradient overlay on hover */}
            <div className="absolute inset-0 bg-gradient-to-br from-indigo-50/50 to-transparent rounded-2xl opacity-0 group-hover:opacity-100 transition-opacity duration-300" />

            <div className="relative z-10">
                <div className="flex items-start justify-between mb-4">
                    <div className="flex-1">
                        <p className="text-sm font-medium text-slate-500 mb-1">{title}</p>
                        <h3 className="text-3xl font-bold text-slate-800">{value}</h3>
                    </div>
                    {Icon && (
                        <div className="p-3 bg-gradient-to-br from-indigo-500 to-indigo-600 rounded-xl shadow-md group-hover:shadow-lg transition-shadow duration-300">
                            <Icon className="w-6 h-6 text-white" />
                        </div>
                    )}
                </div>

                {trend !== undefined && trend !== null && (
                    <div className="flex items-center gap-1">
                        {isPositiveTrend ? (
                            <TrendingUp className="w-4 h-4 text-green-500" />
                        ) : isNegativeTrend ? (
                            <TrendingDown className="w-4 h-4 text-red-500" />
                        ) : null}
                        <span className={`text-sm font-medium ${isPositiveTrend ? 'text-green-600' :
                                isNegativeTrend ? 'text-red-600' :
                                    'text-slate-500'
                            }`}>
                            {trend > 0 ? '+' : ''}{trend}%
                        </span>
                        <span className="text-xs text-slate-400 ml-1">vs last week</span>
                    </div>
                )}
            </div>
        </div>
    );
}
