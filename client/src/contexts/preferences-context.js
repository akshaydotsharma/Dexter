import { createContext, useContext } from 'react';

/**
 * Bare context + hook + defaults split out from PreferencesContext.jsx so
 * react-refresh can fast-refresh the provider component cleanly. Keep
 * non-component exports here, the JSX provider over there.
 */

export const DEFAULT_PREFERENCES = {
  theme: 'system',
  default_view: 'today',
  density: 'comfortable',
  sidebar_collapsed_default: true,
  wordmark: 'Dashy',
};

export const PreferencesContext = createContext({
  preferences: DEFAULT_PREFERENCES,
  updatePreferences: async () => {},
  ready: false,
});

export function usePreferences() {
  return useContext(PreferencesContext);
}
