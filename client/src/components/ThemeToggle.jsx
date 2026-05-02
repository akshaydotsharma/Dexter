import { Moon, Monitor, Sun } from 'lucide-react';
import { usePreferences } from '../contexts/preferences-context';

/**
 * v2 ThemeToggle — cycles light → dark → system → light. The icon shown
 * reflects the *current* mode (Sun for light, Moon for dark, Monitor for
 * system) so a single click both toggles and previews the next state via
 * its tooltip.
 */
const NEXT = { light: 'dark', dark: 'system', system: 'light' };
const ICONS = { light: Sun, dark: Moon, system: Monitor };
const LABELS = { light: 'Light', dark: 'Dark', system: 'System' };

export default function ThemeToggle({ className = '' }) {
  const { preferences, updatePreferences } = usePreferences();
  const theme = preferences.theme || 'system';
  const Icon = ICONS[theme] || Monitor;
  const next = NEXT[theme] || 'light';

  return (
    <button
      type="button"
      onClick={() => updatePreferences({ theme: next })}
      aria-label={`Theme: ${LABELS[theme]}. Switch to ${LABELS[next]}.`}
      title={`Theme: ${LABELS[theme]} (click for ${LABELS[next]})`}
      className={
        'inline-flex items-center justify-center w-9 h-9 rounded-lg text-ink-soft hover:bg-paper-2 ' +
        'transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
        className
      }
    >
      <Icon size={18} strokeWidth={1.75} aria-hidden="true" />
    </button>
  );
}
