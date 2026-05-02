import Eyebrow from './Eyebrow';

/**
 * v2 PageTitle — the Calistoga page hero with the 2px accent underline.
 * Renders Eyebrow (optional), then the H1, then a 32px-wide accent rail
 * sitting 8px below the baseline, then an optional muted subtitle.
 */
export default function PageTitle({ eyebrow, children, subtitle, className = '' }) {
  return (
    <header className={className}>
      {eyebrow ? (
        <Eyebrow accent className="mb-2 inline-block">
          {eyebrow}
        </Eyebrow>
      ) : null}
      <h1
        className="font-display text-3xl text-ink leading-tight tracking-tight"
        style={{ letterSpacing: '-0.01em' }}
      >
        {children}
      </h1>
      <span
        aria-hidden="true"
        className="block h-[2px] w-8 bg-[--color-accent] mt-2"
      />
      {subtitle ? (
        <p className="mt-3 text-sm text-muted leading-[1.55]">{subtitle}</p>
      ) : null}
    </header>
  );
}
