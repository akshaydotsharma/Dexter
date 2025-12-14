export default function Card({ children, className = '', title, actions, style = {}, hideTitle = false }) {
    return (
        <div className={`bg-white/80 backdrop-blur-xl border border-white/20 shadow-xl rounded-2xl p-6 transition-all duration-300 hover:shadow-2xl ${className}`} style={style}>
            {!hideTitle && (title || actions) && (
                <div className="flex justify-between items-center mb-4 flex-shrink-0">
                    {title && <h2 className="text-xl font-semibold text-gray-800 tracking-tight">{title}</h2>}
                    {actions && <div className="flex gap-2">{actions}</div>}
                </div>
            )}
            {children}
        </div>
    );
}
