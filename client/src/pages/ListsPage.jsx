import ListsWidget from '../components/ListsWidget';
import PageTitle from '../components/PageTitle';
import { useActivityFocus } from '../hooks/useActivityFocus';

/**
 * v2 Lists page — wraps ListsWidget under the new shell.
 * Honours `?focus=<id>` from the Activity timeline deep-link.
 */
export default function ListsPage() {
  useActivityFocus();
  return (
    <div className="px-6 md:px-10 py-8 max-w-3xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle subtitle="Curated checklists.">
        Lists
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <ListsWidget fullHeight />
      </div>
    </div>
  );
}
