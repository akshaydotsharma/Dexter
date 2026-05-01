import { forwardRef } from 'react';

/**
 * v2 Button primitive.
 *
 * Variants:
 *   primary   — bg-ink (the brand mark), used for confirm/submit
 *   secondary — bordered surface, neutral default action
 *   ghost     — transparent, used inside dense rows
 *   accent    — uses the active route accent (per-section ink)
 *   danger    — destructive
 *
 * Sizes: sm (h-8) | md (h-10, default) | lg (h-12)
 */
const Button = forwardRef(function Button(
  { children, variant = 'primary', size = 'md', className = '', type = 'button', disabled, ...props },
  ref
) {
  const base =
    'inline-flex items-center justify-center gap-2 font-medium rounded-lg transition-colors duration-150 ease-out ' +
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
    'disabled:bg-paper-2 disabled:text-muted-soft disabled:cursor-not-allowed';

  const sizes = {
    sm: 'h-8 px-3 text-sm',
    md: 'h-10 px-4 text-sm',
    lg: 'h-12 px-5 text-base',
  };

  const variants = {
    primary: 'bg-ink text-paper hover:bg-ink-soft',
    secondary: 'bg-surface border border-border text-ink hover:bg-paper-2',
    ghost: 'text-ink hover:bg-paper-2',
    accent: 'bg-[--color-accent] text-[--color-accent-fg] hover:opacity-90',
    danger: 'bg-danger text-white hover:opacity-90',
  };

  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled}
      className={`${base} ${sizes[size]} ${variants[variant]} ${className}`}
      {...props}
    >
      {children}
    </button>
  );
});

export default Button;
