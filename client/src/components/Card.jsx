/**
 * v2 Card primitive.
 *
 * Editorial Calm: borders carry the weight, no shadows at rest, no glass.
 * Default padding p-5 (20px) — override with the `padding` prop or className.
 */
export default function Card({
  children,
  className = '',
  title,
  actions,
  style = {},
  hideTitle = false,
  hoverable = false,
  padding = 'p-5',
}) {
  const hover = hoverable
    ? 'hover:border-border-strong transition-colors duration-150 ease-out'
    : '';

  return (
    <div
      className={`bg-surface border border-border rounded-xl ${padding} ${hover} ${className}`}
      style={style}
    >
      {!hideTitle && (title || actions) && (
        <div className="flex justify-between items-center mb-4 flex-shrink-0">
          {title && (
            <h2 className="text-lg font-medium text-ink tracking-tight">{title}</h2>
          )}
          {actions && <div className="flex gap-2">{actions}</div>}
        </div>
      )}
      {children}
    </div>
  );
}
