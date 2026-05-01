import { forwardRef } from 'react';

/**
 * v2 Input primitive. Sizes parallel Button; focus border + ring use the
 * active route accent so an input on /tasks shows indigo, on /notes amber.
 */
const Input = forwardRef(function Input(
  { className = '', size = 'md', ...props },
  ref
) {
  const sizes = {
    sm: 'h-8 px-3 text-sm',
    md: 'h-10 px-3.5 text-sm',
    lg: 'h-12 px-4 text-base',
  };

  return (
    <input
      ref={ref}
      className={
        'w-full rounded-lg bg-surface border border-border text-ink placeholder:text-muted-soft ' +
        'transition-colors duration-150 ease-out outline-none ' +
        'focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring] ' +
        `${sizes[size]} ${className}`
      }
      {...props}
    />
  );
});

export default Input;
