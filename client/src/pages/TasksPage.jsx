import TodoWidget from '../components/TodoWidget';
import PageTitle from '../components/PageTitle';
import { useActivityFocus } from '../hooks/useActivityFocus';

/**
 * v2 Tasks page — thin wrapper around the existing TodoWidget so it
 * mounts under the new AppShell. The widget itself doesn't get the
 * v2 visual treatment yet (that's step 7); this just re-parents it.
 *
 * Activity timeline deep-link: when arriving with `?focus=<id>` the
 * useActivityFocus hook scrolls the matching row (data-activity-id) into
 * view and pulses it via the global `[data-activity-focus]` CSS rule.
 */
export default function TasksPage() {
  useActivityFocus();
  return (
    <div className="px-6 md:px-10 py-8 max-w-3xl mx-auto w-full h-full flex flex-col min-h-0">
      <PageTitle subtitle="Capture, defer, complete.">
        Tasks
      </PageTitle>
      <div className="mt-8 flex-1 min-h-0">
        <TodoWidget fullHeight />
      </div>
    </div>
  );
}
