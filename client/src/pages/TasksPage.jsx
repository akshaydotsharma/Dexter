import TodoWidget from '../components/TodoWidget';
import PageTitle from '../components/PageTitle';

/**
 * v2 Tasks page — thin wrapper around the existing TodoWidget so it
 * mounts under the new AppShell. The widget itself doesn't get the
 * v2 visual treatment yet (that's step 7); this just re-parents it.
 */
export default function TasksPage() {
  return (
    <div className="px-6 md:px-10 py-8 max-w-3xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle eyebrow="Tasks" subtitle="Capture, defer, complete.">
        Tasks
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <TodoWidget fullHeight />
      </div>
    </div>
  );
}
