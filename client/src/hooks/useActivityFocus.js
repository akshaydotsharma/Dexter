import { useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';

/**
 * Reads `?focus=<id>` from the current URL. Once the destination widget has
 * rendered the row with `data-activity-id={id}`, this hook scrolls it into
 * view, toggles `data-activity-focus="true"` to trigger the 600ms accent
 * pulse defined in `index.css`, and finally strips the param from the URL
 * so a refresh doesn't re-pulse forever.
 *
 * The hook polls a few times because the widget may not have data on first
 * paint (it's still fetching). We give it ~2 seconds before giving up.
 *
 * Honours `prefers-reduced-motion` by skipping the pulse animation (the
 * global media query in index.css collapses animation-duration so the
 * data-activity-focus attribute fades immediately) and using `auto` scroll.
 */
export function useActivityFocus(scope = 'activity-id') {
  const location = useLocation();
  const navigate = useNavigate();

  useEffect(() => {
    const params = new URLSearchParams(location.search);
    const focusId = params.get('focus');
    if (!focusId) return undefined;

    const reducedMotion = typeof window !== 'undefined' &&
      window.matchMedia &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    let cancelled = false;
    let attempts = 0;
    const maxAttempts = 20; // ~2s at 100ms intervals

    const tryFocus = () => {
      if (cancelled) return;
      const node = document.querySelector(`[data-${scope}="${focusId}"]`);
      if (node) {
        try {
          node.scrollIntoView({
            behavior: reducedMotion ? 'auto' : 'smooth',
            block: 'center',
          });
        } catch {
          node.scrollIntoView();
        }
        node.setAttribute('data-activity-focus', 'true');
        // Remove after the 600ms pulse so a re-render doesn't re-trigger.
        const cleanupId = window.setTimeout(() => {
          if (!cancelled) node.removeAttribute('data-activity-focus');
        }, 700);
        // Strip the param from the URL so refresh doesn't re-pulse.
        const newSearch = new URLSearchParams(location.search);
        newSearch.delete('focus');
        navigate(
          { pathname: location.pathname, search: newSearch.toString() ? `?${newSearch.toString()}` : '' },
          { replace: true }
        );
        return () => window.clearTimeout(cleanupId);
      }
      attempts += 1;
      if (attempts < maxAttempts) {
        window.setTimeout(tryFocus, 100);
      }
      return undefined;
    };

    const id = window.setTimeout(tryFocus, 50);
    return () => {
      cancelled = true;
      window.clearTimeout(id);
    };
    // We deliberately depend only on the search string so this fires once
    // per navigation. Re-running on `location.pathname` would loop after we
    // strip the param.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.search]);
}
