import { TrendingUp, TrendingDown } from 'lucide-react';

export default function StatsCard({ title, value, trend, className = '' }) {
    const isPositive = typeof trend === 'number' && trend > 0;
    const isNegative = typeof trend === 'number' && trend < 0;
    const hasTrend = typeof trend === 'number' && trend !== 0;

    return (
        <div
            className={
                'group bg-surface border border-border rounded-xl p-5 transition-colors duration-150 ease-out hover:border-border-strong ' +
                className
            }
        >
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">
                {title}
            </p>
            <p
                className="mt-2 font-display text-3xl text-ink leading-none tabular-nums"
                style={{ letterSpacing: '-0.01em' }}
            >
                {value}
            </p>

            {hasTrend && (
                <div className="mt-3 flex items-center gap-1.5">
                    {isPositive ? (
                        <TrendingUp size={14} strokeWidth={1.75} className="text-success" aria-hidden="true" />
                    ) : (
                        <TrendingDown size={14} strokeWidth={1.75} className="text-danger" aria-hidden="true" />
                    )}
                    <span
                        className={
                            'text-xs font-medium tabular-nums ' +
                            (isPositive ? 'text-success' : isNegative ? 'text-danger' : 'text-muted')
                        }
                    >
                        {isPositive ? '+' : ''}{trend}%
                    </span>
                    <span className="text-xs text-muted-soft">vs last week</span>
                </div>
            )}
        </div>
    );
}
