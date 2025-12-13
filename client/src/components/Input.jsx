import { forwardRef } from 'react';

const Input = forwardRef(function Input({ className = '', ...props }, ref) {
    return (
        <input
            ref={ref}
            className={`w-full px-4 py-2 rounded-xl border border-gray-200 bg-white/50 focus:bg-white focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500/20 transition-all duration-200 outline-none placeholder:text-gray-400 text-gray-800 ${className}`}
            {...props}
        />
    );
});

export default Input;
