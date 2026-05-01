/**
 * v2 Kbd — keyboard glyph used in tooltips, Cmd+K trailing hints, and
 * the keyboard-shortcuts cheatsheet. Maps friendly key names to macOS
 * glyphs so callers can write <Kbd>cmd</Kbd> and get ⌘.
 */
const GLYPHS = {
  cmd: '⌘',
  command: '⌘',
  meta: '⌘',
  shift: '⇧',
  alt: '⌥',
  option: '⌥',
  ctrl: '⌃',
  control: '⌃',
  up: '↑',
  down: '↓',
  left: '←',
  right: '→',
  esc: 'Esc',
  escape: 'Esc',
  enter: 'Enter',
  return: 'Enter',
  space: 'Space',
  tab: 'Tab',
  backspace: '⌫',
  delete: 'Del',
};

function mapGlyph(value) {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim();
  const lower = trimmed.toLowerCase();
  if (Object.prototype.hasOwnProperty.call(GLYPHS, lower)) {
    return GLYPHS[lower];
  }
  // Single letters are uppercased so "k" -> "K"
  if (trimmed.length === 1) return trimmed.toUpperCase();
  return trimmed;
}

export default function Kbd({ children, className = '' }) {
  return (
    <kbd
      className={
        'font-mono text-[11px] px-1.5 py-0.5 rounded border border-border bg-paper-2 text-ink-soft inline-flex items-center justify-center min-w-[1.25rem] ' +
        className
      }
    >
      {mapGlyph(children)}
    </kbd>
  );
}
