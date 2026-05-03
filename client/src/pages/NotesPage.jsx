import { useEffect, useRef } from 'react';
import { useLocation } from 'react-router-dom';
import NotesWidget from '../components/NotesWidget';
import PageTitle from '../components/PageTitle';
import { useActivityFocus } from '../hooks/useActivityFocus';

/**
 * v2 Notes page — wraps NotesWidget under the new shell.
 *
 * Activity timeline deep-link:
 *   - `?focus=<note-id>` scrolls to the matching note (handled by useActivityFocus).
 *   - `?folder=<folder-id>` pre-selects the folder via the widget's imperative
 *     `selectFolder` method, so the user lands inside that folder's note list.
 */
export default function NotesPage() {
  const location = useLocation();
  const widgetRef = useRef(null);

  useActivityFocus();

  // Read `?folder=<id>` once on mount + whenever it changes. Pull from
  // location.search rather than useSearchParams to keep this minimal and not
  // pull in extra dependencies.
  const params = new URLSearchParams(location.search);
  const folderParam = params.get('folder');

  useEffect(() => {
    if (!folderParam) return;
    // Defer the imperative call so the widget has time to mount its state
    // and resolve `selectedFolderId` past its initial value.
    const id = window.setTimeout(() => {
      widgetRef.current?.selectFolder?.(folderParam);
    }, 50);
    return () => window.clearTimeout(id);
  }, [folderParam]);

  return (
    <div className="px-6 md:px-10 py-8 max-w-5xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle subtitle="Your notebook.">
        Notes
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <NotesWidget
          ref={widgetRef}
          fullHeight
          initialFolderId={folderParam ?? null}
        />
      </div>
    </div>
  );
}
