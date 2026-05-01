import NotesWidget from '../components/NotesWidget';
import PageTitle from '../components/PageTitle';

/**
 * v2 Notes page — wraps NotesWidget under the new shell. Folder/note
 * URL params will be picked up by the widget itself in step 7.
 */
export default function NotesPage() {
  return (
    <div className="px-6 md:px-10 py-8 max-w-5xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle eyebrow="Notes" subtitle="Your notebook.">
        Notes
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <NotesWidget fullHeight />
      </div>
    </div>
  );
}
