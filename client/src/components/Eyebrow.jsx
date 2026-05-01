/**
 * v2 Eyebrow — the mono uppercase tracked label that sits above headings,
 * above stats, and inside Cmd+K group separators. Default color is muted;
 * pass `accent` to switch to the active route accent (used when the
 * eyebrow is hinting at a destination route, e.g. on a draft preview card).
 */
export default function Eyebrow({ children, accent = false, className = '' }) {
  const color = accent ? 'text-[--color-accent]' : 'text-muted';
  return (
    <span
      className={`font-mono text-[11px] uppercase tracking-[0.18em] ${color} ${className}`}
    >
      {children}
    </span>
  );
}
