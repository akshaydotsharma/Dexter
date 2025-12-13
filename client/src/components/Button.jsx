export default function Button({ children, onClick, variant = 'primary', className = '', ...props }) {
    const baseStyles = "px-4 py-2 rounded-xl font-medium transition-all duration-200 active:scale-95 disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer flex items-center justify-center gap-2";

    const variants = {
        primary: "bg-indigo-600 text-white hover:bg-indigo-700 shadow-lg shadow-indigo-500/30",
        secondary: "bg-white text-gray-700 hover:bg-gray-50 border border-gray-200 shadow-sm",
        danger: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg shadow-rose-500/30",
        ghost: "text-gray-600 hover:bg-gray-100/50 hover:text-gray-900",
    };

    return (
        <button
            onClick={onClick}
            className={`${baseStyles} ${variants[variant]} ${className}`}
            {...props}
        >
            {children}
        </button>
    );
}
