import useChat from '../hooks/useChat';
import { ChatContext } from './chat-context';

/**
 * ChatProvider — lifts the full-page /chat state above the route boundary
 * so that navigating away from /chat (e.g. via a SuccessRow link to
 * /tasks/42) and back preserves the conversation. The floating
 * ChatPopover is intentionally NOT plugged into this context — the
 * popover is a scratch surface and resets each time it closes.
 *
 * The matching `useChatContext` hook lives in ./chat-context.js so
 * Vite Fast Refresh stays happy (react-refresh/only-export-components).
 */
export function ChatProvider({ children }) {
  const value = useChat();
  return <ChatContext.Provider value={value}>{children}</ChatContext.Provider>;
}
