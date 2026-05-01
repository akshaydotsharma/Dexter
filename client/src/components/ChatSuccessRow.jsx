import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
    CheckCircle2,
    ChevronRight,
    Calendar,
    Tag,
    Folder,
    ListPlus,
    X,
    Check,
} from 'lucide-react';
import Button from './Button';
import Chip from './Chip';
import {
    getNoteFolders,
    updateList,
    updateNote,
    updateTodo,
} from '../services/api';

/**
 * Maps the kind of next-step action (set in useChat) to chip copy + icon.
 */
const NEXT_STEP_LABELS = {
    'add-due-date': { label: 'Add due date', icon: Calendar },
    'add-tag': { label: 'Add tag', icon: Tag },
    'file-in-folder': { label: 'File in folder', icon: Folder },
    'add-items': { label: 'Add items', icon: ListPlus },
};

function formatDueDate(iso) {
    try {
        return new Date(iso).toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit',
        });
    } catch {
        return iso;
    }
}

/**
 * ChatSuccessRow — renders a `success` log entry and, when the user taps
 * one of the next-step chips, swaps in the matching inline editor. Used by
 * both the full-page chat and the popover so the post-confirm UX is
 * consistent. When the entity-link chip is clicked we call `onLinkClick`
 * (used by the popover to close itself before navigating).
 */
export default function ChatSuccessRow({ entry, logIndex, onApplyEdit, onLinkClick }) {
    const [activeEditor, setActiveEditor] = useState(null); // 'add-due-date' | 'add-tag' | 'file-in-folder' | 'add-items'
    const [draftValue, setDraftValue] = useState('');
    const [isSaving, setIsSaving] = useState(false);
    const [error, setError] = useState(null);
    const [folders, setFolders] = useState([]);

    useEffect(() => {
        if (activeEditor !== 'file-in-folder') return;
        let cancelled = false;
        getNoteFolders()
            .then((res) => { if (!cancelled) setFolders(res.data || []); })
            .catch(() => { if (!cancelled) setFolders([]); });
        return () => { cancelled = true; };
    }, [activeEditor]);

    const result = entry.draftMeta?.result || {};
    const entityType = entry.draftMeta?.entityType;

    const startEditor = (kind) => {
        setError(null);
        setActiveEditor(kind);
        setDraftValue('');
    };

    const cancelEditor = () => {
        setActiveEditor(null);
        setDraftValue('');
        setError(null);
    };

    const saveEditor = async () => {
        if (!result.id) return;
        setIsSaving(true);
        setError(null);
        try {
            if (activeEditor === 'add-due-date') {
                if (!draftValue) { cancelEditor(); return; }
                const iso = new Date(draftValue).toISOString();
                await updateTodo(result.id, { due_date: iso });
                onApplyEdit(logIndex, { due_date: iso }, `Due date set to ${formatDueDate(iso)}.`);
            } else if (activeEditor === 'add-tag') {
                const tag = draftValue.trim();
                if (!tag) { cancelEditor(); return; }
                await updateTodo(result.id, { tag });
                onApplyEdit(logIndex, { tag }, `Tag #${tag} added.`);
            } else if (activeEditor === 'file-in-folder') {
                if (!draftValue) { cancelEditor(); return; }
                const folderId = Number(draftValue);
                const folder = folders.find((f) => f.id === folderId);
                await updateNote(result.id, result.title, result.content, folderId);
                onApplyEdit(
                    logIndex,
                    { folder_id: folderId },
                    `Filed in ${folder?.name || 'folder'}.`,
                );
            } else if (activeEditor === 'add-items') {
                const items = draftValue
                    .split('\n')
                    .map((s) => s.trim())
                    .filter(Boolean)
                    .map((text) => ({ text, checked: false }));
                if (items.length === 0) { cancelEditor(); return; }
                await updateList(result.id, result.title, items);
                onApplyEdit(
                    logIndex,
                    { items },
                    `${items.length} item${items.length === 1 ? '' : 's'} added.`,
                );
            }
            cancelEditor();
        } catch (err) {
            setError(err.response?.data?.error || err.message || 'Save failed');
        } finally {
            setIsSaving(false);
        }
    };

    return (
        <div className="space-y-2 motion-safe:animate-in motion-safe:fade-in motion-safe:duration-200">
            {/* Status row */}
            <div
                className="flex items-center gap-2 flex-wrap text-sm text-ink-soft"
                role="status"
            >
                <CheckCircle2
                    className="text-success"
                    size={16}
                    strokeWidth={1.75}
                    aria-hidden="true"
                />
                <span>{entry.text}</span>

                {entry.link ? (
                    <Link
                        to={entry.link.to}
                        onClick={onLinkClick}
                        className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium text-[--color-accent] hover:bg-[--color-accent-soft] transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
                    >
                        <span>{entry.link.label}</span>
                        <ChevronRight size={14} strokeWidth={1.75} aria-hidden="true" />
                    </Link>
                ) : null}

                {(entry.actions || []).map((action) => {
                    const meta = NEXT_STEP_LABELS[action.kind];
                    if (!meta) return null;
                    return (
                        <Chip
                            key={action.kind}
                            variant="action"
                            icon={meta.icon}
                            onClick={() => startEditor(action.kind)}
                        >
                            {meta.label}
                        </Chip>
                    );
                })}
            </div>

            {/* Inline editor (datetime / tag / folder / items) */}
            {activeEditor && (
                <div className="ml-6 bg-surface border border-border rounded-xl p-3 space-y-2 motion-safe:animate-in motion-safe:fade-in motion-safe:slide-in-from-top-1 motion-safe:duration-150">
                    {activeEditor === 'add-due-date' && (
                        <input
                            type="datetime-local"
                            autoFocus
                            value={draftValue}
                            onChange={(e) => setDraftValue(e.target.value)}
                            className="w-full rounded-lg bg-surface border border-border text-ink text-sm px-3 py-2 outline-none focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring]"
                        />
                    )}

                    {activeEditor === 'add-tag' && (
                        <input
                            type="text"
                            autoFocus
                            placeholder="Tag (e.g. work)"
                            value={draftValue}
                            onChange={(e) => setDraftValue(e.target.value)}
                            onKeyDown={(e) => {
                                if (e.key === 'Enter') saveEditor();
                            }}
                            className="w-full rounded-lg bg-surface border border-border text-ink text-sm px-3 py-2 outline-none focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring] placeholder:text-muted-soft"
                        />
                    )}

                    {activeEditor === 'file-in-folder' && (
                        <select
                            autoFocus
                            value={draftValue}
                            onChange={(e) => setDraftValue(e.target.value)}
                            className="w-full rounded-lg bg-surface border border-border text-ink text-sm px-3 py-2 outline-none focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring]"
                        >
                            <option value="">Choose a folder…</option>
                            {folders.map((folder) => (
                                <option key={folder.id} value={folder.id}>{folder.name}</option>
                            ))}
                        </select>
                    )}

                    {activeEditor === 'add-items' && (
                        <textarea
                            autoFocus
                            placeholder="One item per line"
                            value={draftValue}
                            onChange={(e) => setDraftValue(e.target.value)}
                            className="w-full rounded-lg bg-surface border border-border text-ink text-sm px-3 py-2 outline-none focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring] placeholder:text-muted-soft min-h-[80px] resize-none font-mono"
                        />
                    )}

                    {error && <p className="text-xs text-danger">{error}</p>}

                    <div className="flex gap-2">
                        <Button variant="primary" size="sm" onClick={saveEditor} disabled={isSaving}>
                            <Check size={14} strokeWidth={1.75} aria-hidden="true" />
                            Save
                        </Button>
                        <Button variant="ghost" size="sm" onClick={cancelEditor} disabled={isSaving}>
                            <X size={14} strokeWidth={1.75} aria-hidden="true" />
                            Cancel
                        </Button>
                    </div>
                </div>
            )}
        </div>
    );
}
