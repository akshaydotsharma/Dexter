import LanguageInputPage from './LanguageInputPage';

/**
 * v2 Chat page — re-mounts the existing LanguageInputPage under the new
 * shell. Streaming refactor lands in step 6.
 */
export default function ChatPage() {
  return (
    <div className="h-full flex flex-col min-h-0">
      <LanguageInputPage />
    </div>
  );
}
