import { useCallback, useState } from 'react';
import { aiParse, executeDraft as apiExecuteDraft, rejectDraft as apiRejectDraft } from '../services/api';

/**
 * useChat — shared chat state machine consumed by both the full-page
 * /chat surface and the floating ChatPopover. Owns the logs[], the
 * pendingDrafts[], and the flow of (parse → preview → confirm) → success.
 *
 * Log entry shapes:
 *   { role: 'user',    content: string }
 *   { role: 'system',  content: string }   plain AI prose, no chrome
 *   { role: 'success', text, link?, actions?, draftMeta }
 *
 * The hook does NOT do streaming yet — it calls the existing single-shot
 * endpoints (`aiParse`, `executeDraft`, `rejectDraft`). When the server
 * exposes /api/ai/parse/stream, the `send` function below is where the
 * SSE consumer will live; the rest of the state machine stays the same.
 */

const friendlyVerb = {
  CREATE_TODO: 'Created',
  CREATE_NOTE: 'Created',
  CREATE_LIST: 'Created',
  UPDATE_TODO: 'Updated',
  UPDATE_NOTE: 'Updated',
  UPDATE_LIST: 'Updated',
  COMPLETE_TODO: 'Completed',
  ADD_TO_LIST: 'Added to',
  UPDATE_LIST_ITEM: 'Updated item in',
  REMOVE_LIST_ITEM: 'Removed item from',
  UPDATE_FOLDER: 'Renamed',
  DELETE_TODO: 'Deleted',
  DELETE_NOTE: 'Deleted',
  DELETE_LIST: 'Deleted',
  DELETE_FOLDER: 'Deleted',
};

function buildSuccessText(actionType, entityType, result, fallbackMessage) {
  const verb = friendlyVerb[actionType] || 'Updated';
  const title =
    result?.title ||
    result?.name ||
    (entityType ? entityType : 'item');

  if (actionType?.startsWith('DELETE')) {
    return `Deleted ${entityType}.`;
  }

  if (actionType === 'COMPLETE_TODO') {
    return result?.completed === false
      ? `Marked "${title}" as not done.`
      : `Completed "${title}".`;
  }

  if (title) {
    return `${verb} "${title}".`;
  }

  return fallbackMessage || `${verb}.`;
}

function buildEntityLink(actionType, entityType, result) {
  if (!result || !result.id) return null;
  if (actionType?.startsWith('DELETE')) return null;

  if (entityType === 'todo') {
    return { to: `/tasks/${result.id}`, label: 'Open in Tasks' };
  }
  if (entityType === 'note') {
    const folder = result.folder_id ?? 'all';
    return { to: `/notes/${folder}/${result.id}`, label: 'View note' };
  }
  if (entityType === 'list') {
    return { to: `/lists/${result.id}`, label: 'Open list' };
  }
  return null;
}

function buildNextStepActions({ actionType, entityType, result }) {
  // Only CREATE_* gets next-step suggestions for now.
  if (!actionType?.startsWith('CREATE_')) return [];
  if (!result) return [];
  const actions = [];

  if (entityType === 'todo') {
    if (!result.due_date) actions.push({ kind: 'add-due-date' });
    if (!result.tag) actions.push({ kind: 'add-tag' });
  } else if (entityType === 'note') {
    if (!result.folder_id) actions.push({ kind: 'file-in-folder' });
  } else if (entityType === 'list') {
    const items = Array.isArray(result.items) ? result.items : [];
    if (items.length === 0) actions.push({ kind: 'add-items' });
  }

  return actions.slice(0, 2);
}

export default function useChat() {
  const [logs, setLogs] = useState([]);
  const [pendingDrafts, setPendingDrafts] = useState([]);
  const [isProcessing, setIsProcessing] = useState(false);

  const pushLog = useCallback((entry) => {
    setLogs((prev) => [...prev, entry]);
  }, []);

  // TODO: streaming wiring lands when /api/ai/parse/stream is available.
  // The stream will replace the single-shot aiParse() below; logs/drafts
  // contracts stay the same so consumers don't need to change.
  const send = useCallback(async (text) => {
    if (!text || !text.trim()) return;
    pushLog({ role: 'user', content: text });
    setIsProcessing(true);
    try {
      const response = await aiParse(text);
      const data = response.data || {};

      if (Array.isArray(data.drafts) && data.drafts.length > 0) {
        setPendingDrafts((prev) => [...prev, ...data.drafts]);
      }

      if (data.assistantText) {
        pushLog({ role: 'system', content: data.assistantText });
      } else if (!data.success && !(data.drafts?.length)) {
        pushLog({
          role: 'system',
          content: "I didn't catch that. Try a todo, note, or list.",
        });
      }
    } catch (error) {
      const message =
        error.response?.data?.error || error.message || 'Failed to process request';
      pushLog({ role: 'system', content: `Error: ${message}` });
    } finally {
      setIsProcessing(false);
    }
  }, [pushLog]);

  const confirmDraft = useCallback(async (draftId, updatedData) => {
    setIsProcessing(true);
    try {
      const draftBefore = pendingDrafts.find((d) => d.id === draftId);
      const response = await apiExecuteDraft(draftId, updatedData);
      const data = response.data || {};

      if (data.success) {
        setPendingDrafts((prev) => prev.filter((d) => d.id !== draftId));

        const actionType = draftBefore?.action_type;
        const entityType = draftBefore?.entity_type;
        const result = data.result || {};

        const text = buildSuccessText(actionType, entityType, result, data.message);
        const link = buildEntityLink(actionType, entityType, result);
        const actions = buildNextStepActions({ actionType, entityType, result });

        const entry = {
          role: 'success',
          text,
          link,
          actions,
          draftMeta: {
            actionType,
            entityType,
            result,
          },
        };
        pushLog(entry);
        return { success: true, result, entry };
      }

      pushLog({
        role: 'system',
        content: data.message || 'Draft execution failed.',
      });
      return { success: false };
    } catch (error) {
      const message =
        error.response?.data?.error || error.message || 'Failed to execute';
      pushLog({ role: 'system', content: `Error: ${message}` });
      return { success: false, error };
    } finally {
      setIsProcessing(false);
    }
  }, [pendingDrafts, pushLog]);

  const rejectDraft = useCallback(async (draftId) => {
    setIsProcessing(true);
    try {
      await apiRejectDraft(draftId);
      setPendingDrafts((prev) => prev.filter((d) => d.id !== draftId));
      pushLog({ role: 'system', content: 'Draft dismissed.' });
    } catch (error) {
      const message =
        error.response?.data?.error || error.message || 'Failed to reject';
      pushLog({ role: 'system', content: `Error: ${message}` });
    } finally {
      setIsProcessing(false);
    }
  }, [pushLog]);

  /**
   * applyInlineEdit — used by next-step chips when the user fills a missing
   * field after a draft has been executed (e.g. adds a due date to a just-
   * created todo). Mutates the matching success log entry to reflect the
   * new state.
   *
   * args:
   *   logIndex — index of the success log entry being mutated
   *   patch    — partial result to merge ({ due_date, tag, folder_id, items, ... })
   *   note     — short status the row should now show ("Due date set to ...")
   */
  const applyInlineEdit = useCallback((logIndex, patch, note) => {
    setLogs((prev) => prev.map((entry, idx) => {
      if (idx !== logIndex) return entry;
      if (entry.role !== 'success') return entry;
      const nextResult = { ...(entry.draftMeta?.result || {}), ...patch };
      // Once a missing field is filled, drop the corresponding next-step chip.
      const nextActions = (entry.actions || []).filter((a) => {
        if (a.kind === 'add-due-date' && patch.due_date) return false;
        if (a.kind === 'add-tag' && patch.tag) return false;
        if (a.kind === 'file-in-folder' && patch.folder_id) return false;
        if (a.kind === 'add-items' && Array.isArray(patch.items) && patch.items.length > 0) return false;
        return true;
      });
      return {
        ...entry,
        text: note || entry.text,
        actions: nextActions,
        draftMeta: { ...entry.draftMeta, result: nextResult },
      };
    }));
  }, []);

  return {
    logs,
    pendingDrafts,
    isProcessing,
    send,
    confirmDraft,
    rejectDraft,
    applyInlineEdit,
  };
}
