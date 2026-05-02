/**
 * v2 Chip primitive.
 *
 * Variants:
 *   neutral — default chrome chip (e.g. tag, helper count)
 *   accent  — uses the route accent; for state-of-this-page emphasis
 *   success / warning / danger — semantic only
 *   link    — entity-link chip used in SuccessRow ("View in Tasks ›")
 *   action  — next-step chip ("Add due date") with darker hover
 *
 * If `onClick` is provided, renders as <button>; otherwise as <span>.
 * Lucide icons render at icon-xs (14px) inside chips. Pass them via
 * the `icon` prop (component reference) — primitive does not import Lucide
 * itself, callers do.
 */
export default function Chip({
  children,
  variant = 'neutral',
  icon: Icon,
  iconTrailing: IconTrailing,
  onClick,
  className = '',
  ariaLabel,
  ...rest
}) {
  const base =
    'inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium transition-colors duration-150 ease-out';

  const variants = {
    neutral: 'bg-paper-2 text-ink-soft',
    accent: 'bg-[--color-accent-soft] text-[--color-accent]',
    success: 'bg-success-soft text-success',
    warning: 'bg-warning-soft text-warning',
    danger: 'bg-danger-soft text-danger',
    link: 'text-[--color-accent] hover:bg-[--color-accent-soft]',
    action: 'bg-paper-2 text-ink hover:bg-border',
  };

  const interactive = onClick
    ? 'cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]'
    : '';

  const inner = (
    <>
      {Icon ? <Icon size={14} strokeWidth={1.75} aria-hidden="true" /> : null}
      <span>{children}</span>
      {IconTrailing ? <IconTrailing size={14} strokeWidth={1.75} aria-hidden="true" /> : null}
    </>
  );

  if (onClick) {
    return (
      <button
        type="button"
        onClick={onClick}
        aria-label={ariaLabel}
        className={`${base} ${variants[variant]} ${interactive} ${className}`}
        {...rest}
      >
        {inner}
      </button>
    );
  }

  return (
    <span
      aria-label={ariaLabel}
      className={`${base} ${variants[variant]} ${className}`}
      {...rest}
    >
      {inner}
    </span>
  );
}
