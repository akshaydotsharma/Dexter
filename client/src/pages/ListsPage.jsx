import ListsWidget from '../components/ListsWidget';
import PageTitle from '../components/PageTitle';

/**
 * v2 Lists page — wraps ListsWidget under the new shell.
 */
export default function ListsPage() {
  return (
    <div className="px-6 md:px-10 py-8 max-w-3xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle eyebrow="Lists" subtitle="Curated checklists.">
        Lists
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <ListsWidget fullHeight />
      </div>
    </div>
  );
}
