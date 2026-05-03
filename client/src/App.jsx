import { Navigate, Route, Routes } from 'react-router-dom';
import { PreferencesProvider } from './contexts/PreferencesContext';
import AppShell from './components/AppShell';
import PlaceholderPage from './pages/PlaceholderPage';
import ChatPage from './pages/ChatPage';
import TasksPage from './pages/TasksPage';
import NotesPage from './pages/NotesPage';
import ListsPage from './pages/ListsPage';
import DashboardPage from './pages/DashboardPage';
import ActivityPage from './pages/ActivityPage';

/**
 * v2 App — wraps the route tree in PreferencesProvider, then mounts every
 * route under the AppShell layout. BrowserRouter lives in main.jsx.
 *
 * Routes for steps 1–3 (chrome only):
 *   /                   → /today
 *   /today              → placeholder
 *   /chat               → existing LanguageInputPage (no streaming yet, step 6)
 *   /tasks, /tasks/:id  → TodoWidget full-height
 *   /notes/...          → NotesWidget
 *   /lists, /lists/:id  → ListsWidget
 *   /dashboard          → bento grid extracted from legacy App.jsx
 *   /settings           → /settings/appearance
 *   /settings/:section  → placeholder
 *   *                   → /today
 */
function SettingsPlaceholder({ sectionLabel }) {
  return (
    <PlaceholderPage
      eyebrow={`Settings · ${sectionLabel}`}
      title="Settings"
      subtitle={`The ${sectionLabel.toLowerCase()} settings panel ships in step 8.`}
    />
  );
}

export default function App() {
  return (
    <PreferencesProvider>
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<Navigate to="/today" replace />} />

          <Route
            path="/today"
            element={
              <PlaceholderPage
                eyebrow="Today"
                title="Today"
                subtitle="Your morning-coffee surface. The Today feed lands in step 8."
              />
            }
          />

          <Route path="/chat" element={<ChatPage />} />

          <Route path="/tasks" element={<TasksPage />} />
          <Route path="/tasks/:id" element={<TasksPage />} />

          <Route path="/notes" element={<NotesPage />} />
          <Route path="/notes/:folderId" element={<NotesPage />} />
          <Route path="/notes/:folderId/:noteId" element={<NotesPage />} />

          <Route path="/lists" element={<ListsPage />} />
          <Route path="/lists/:id" element={<ListsPage />} />

          <Route path="/dashboard" element={<DashboardPage />} />

          <Route path="/activity" element={<ActivityPage />} />

          <Route path="/settings" element={<Navigate to="/settings/appearance" replace />} />
          <Route path="/settings/appearance" element={<SettingsPlaceholder sectionLabel="Appearance" />} />
          <Route path="/settings/defaults" element={<SettingsPlaceholder sectionLabel="Defaults" />} />
          <Route path="/settings/keyboard" element={<SettingsPlaceholder sectionLabel="Keyboard" />} />
          <Route path="/settings/ai" element={<SettingsPlaceholder sectionLabel="AI & Chat" />} />
          <Route path="/settings/account" element={<SettingsPlaceholder sectionLabel="Account" />} />

          <Route path="*" element={<Navigate to="/today" replace />} />
        </Route>
      </Routes>
    </PreferencesProvider>
  );
}
