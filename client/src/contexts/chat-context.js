import { createContext, useContext } from 'react';

/**
 * Plain context + hook lives in this .js file so the matching .jsx
 * Provider file can stay component-only (keeps eslint
 * react-refresh/only-export-components happy).
 */
export const ChatContext = createContext(null);

export function useChatContext() {
  const ctx = useContext(ChatContext);
  if (!ctx) {
    throw new Error('useChatContext must be used inside <ChatProvider>');
  }
  return ctx;
}
