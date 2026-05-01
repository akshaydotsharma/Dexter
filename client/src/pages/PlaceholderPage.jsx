import PageTitle from '../components/PageTitle';
import Eyebrow from '../components/Eyebrow';

/**
 * v2 Placeholder — used by /today, /settings/:section, and /dashboard
 * during steps 1–3 before their real implementations land in step 8.
 *
 * Renders a Calistoga page title with the per-route accent underline so
 * the user can verify the chrome (sidebar rail color, page underline,
 * eyebrow tint) is wired correctly before we start swapping content.
 */
export default function PlaceholderPage({ eyebrow, title, subtitle, children }) {
  return (
    <div className="px-6 md:px-10 py-10 max-w-3xl mx-auto w-full">
      <PageTitle eyebrow={eyebrow} subtitle={subtitle}>
        {title}
      </PageTitle>

      <div className="mt-10 space-y-6 text-sm text-ink-soft leading-[1.55]">
        {children || (
          <>
            <p>
              This page is a placeholder while the v2 refactor lands. The
              chrome you see (sidebar accent rail, page-title underline, the
              eyebrow above) is the per-section accent for this route.
            </p>
            <div className="border-t border-divider pt-6">
              <Eyebrow>Status</Eyebrow>
              <p className="mt-2">
                Steps 1–3 (tokens, primitives, shell) are in place. The real
                page lands in step 8.
              </p>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
