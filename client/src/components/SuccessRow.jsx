import { CheckCircle2, ChevronRight } from 'lucide-react';
import { Link } from 'react-router-dom';
import Chip from './Chip';

/**
 * v2 SuccessRow — the chat success state. Replaces "✅ <message>" strings
 * with a structured row: success check + status text + entity-link chip
 * + 0–2 next-step action chips.
 *
 * Props:
 *   text     — string  (required)
 *   link     — { to, label }  optional, renders an entity-link chip
 *              that uses react-router-dom <Link> under the hood
 *   actions  — Array<{ label, icon?, onClick }>  0–2 next-step chips
 *
 * Note: this component is registered in step 2 so step 6 can wire it
 * into ChatPopover and LanguageInputPage without re-creating chrome.
 */
export default function SuccessRow({ text, link, actions = [], className = '' }) {
  return (
    <div
      className={`flex items-center gap-2 flex-wrap py-2 text-sm text-ink-soft ${className}`}
      role="status"
    >
      <CheckCircle2
        className="text-success"
        size={16}
        strokeWidth={1.75}
        aria-hidden="true"
      />
      <span>{text}</span>

      {link ? (
        <Link
          to={link.to}
          className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium text-[--color-accent] hover:bg-[--color-accent-soft] transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
        >
          <span>{link.label}</span>
          <ChevronRight size={14} strokeWidth={1.75} aria-hidden="true" />
        </Link>
      ) : null}

      {actions.slice(0, 2).map((action, idx) => (
        <Chip
          key={`${action.label}-${idx}`}
          variant="action"
          icon={action.icon}
          onClick={action.onClick}
        >
          {action.label}
        </Chip>
      ))}
    </div>
  );
}
