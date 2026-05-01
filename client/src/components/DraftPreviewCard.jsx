import { useState } from 'react';
import { Check, X, Pencil, Calendar, Tag, Hash } from 'lucide-react';
import Button from './Button';
import Chip from './Chip';
import Eyebrow from './Eyebrow';
import Input from './Input';

const actionLabels = {
    CREATE_TODO: 'NEW TASK',
    CREATE_NOTE: 'NEW NOTE',
    CREATE_LIST: 'NEW LIST',
    UPDATE_TODO: 'UPDATE TASK',
    UPDATE_NOTE: 'UPDATE NOTE',
    UPDATE_LIST: 'UPDATE LIST',
    COMPLETE_TODO: 'COMPLETE TASK',
    ADD_TO_LIST: 'ADD TO LIST',
    UPDATE_LIST_ITEM: 'UPDATE LIST ITEM',
    REMOVE_LIST_ITEM: 'REMOVE LIST ITEM',
    UPDATE_FOLDER: 'UPDATE FOLDER',
    DELETE_TODO: 'DELETE TASK',
    DELETE_NOTE: 'DELETE NOTE',
    DELETE_LIST: 'DELETE LIST',
    DELETE_FOLDER: 'DELETE FOLDER',
};

const inlineFieldClasses =
    'w-full rounded-lg bg-surface border border-border text-ink placeholder:text-muted-soft text-sm ' +
    'transition-colors duration-150 ease-out outline-none ' +
    'focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring] px-3 py-2';

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

function isWithin24h(iso) {
    if (!iso) return false;
    const t = new Date(iso).getTime();
    if (Number.isNaN(t)) return false;
    const delta = t - Date.now();
    return delta >= 0 && delta <= 24 * 60 * 60 * 1000;
}

export default function DraftPreviewCard({ draft, onConfirm, onReject, onEdit, isProcessing }) {
    const [isInlineEditing, setIsInlineEditing] = useState(false);
    const [editedData, setEditedData] = useState(draft.data || draft.draft_data);

    const actionLabel = actionLabels[draft.action_type] || draft.action_type;
    const data = editedData;

    const handleConfirm = () => {
        if (isInlineEditing) {
            onConfirm(draft.id, editedData);
        } else {
            onConfirm(draft.id);
        }
        setIsInlineEditing(false);
    };

    const handleFieldChange = (field, value) => {
        setEditedData((prev) => ({ ...prev, [field]: value }));
    };

    const handleEdit = () => {
        if (isInlineEditing) {
            setIsInlineEditing(false);
        } else if (onEdit) {
            onEdit(draft);
        } else {
            setIsInlineEditing(true);
        }
    };

    // -----------------------------------------------------------------
    // Card body renderers — read-only ("preview") and inline-edit modes.
    // -----------------------------------------------------------------

    const renderTaskPreview = () => {
        const dueChipVariant = isWithin24h(data.due_date) ? 'warning' : 'neutral';
        return (
            <div className="space-y-2">
                <p className="text-sm font-medium text-ink leading-snug">{data.title}</p>
                {(data.due_date || data.tag) && (
                    <div className="flex flex-wrap items-center gap-1.5">
                        {data.due_date && (
                            <Chip variant={dueChipVariant} icon={Calendar}>
                                {formatDueDate(data.due_date)}
                            </Chip>
                        )}
                        {data.tag && (
                            <Chip variant="neutral" icon={Tag}>
                                {data.tag}
                            </Chip>
                        )}
                    </div>
                )}
            </div>
        );
    };

    const renderTaskEdit = () => (
        <div className="space-y-2">
            <Input
                size="sm"
                value={data.title || ''}
                onChange={(e) => handleFieldChange('title', e.target.value)}
                placeholder="Task title"
                autoFocus
            />
            <div className="flex gap-2">
                <input
                    type="datetime-local"
                    value={data.due_date ? data.due_date.slice(0, 16) : ''}
                    onChange={(e) => handleFieldChange(
                        'due_date',
                        e.target.value ? new Date(e.target.value).toISOString() : null,
                    )}
                    className={`${inlineFieldClasses} flex-1`}
                />
                <input
                    type="text"
                    value={data.tag || ''}
                    onChange={(e) => handleFieldChange('tag', e.target.value)}
                    className={`${inlineFieldClasses} w-32`}
                    placeholder="Tag"
                />
            </div>
        </div>
    );

    const renderNotePreview = () => (
        <div className="space-y-2">
            <p className="text-sm font-medium text-ink leading-snug">{data.title}</p>
            {data.content && (
                <p className="text-xs text-muted leading-relaxed">
                    {data.content.length > 140 ? `${data.content.slice(0, 140)}…` : data.content}
                </p>
            )}
        </div>
    );

    const renderNoteEdit = () => (
        <div className="space-y-2">
            <Input
                size="sm"
                value={data.title || ''}
                onChange={(e) => handleFieldChange('title', e.target.value)}
                placeholder="Note title"
                autoFocus
            />
            <textarea
                value={data.content || ''}
                onChange={(e) => handleFieldChange('content', e.target.value)}
                className={`${inlineFieldClasses} min-h-[80px] resize-none`}
                placeholder="Note content"
            />
        </div>
    );

    const renderListPreview = () => {
        const items = data.items || [];
        const itemCount = items.length;
        return (
            <div className="space-y-2">
                <div className="flex items-center justify-between gap-3">
                    <p className="text-sm font-medium text-ink leading-snug truncate">{data.title}</p>
                    <Chip variant="neutral" icon={Hash}>
                        {itemCount} {itemCount === 1 ? 'item' : 'items'}
                    </Chip>
                </div>
                {itemCount > 0 && (
                    <ul className="text-xs text-muted space-y-0.5">
                        {items.slice(0, 3).map((item, idx) => (
                            <li key={idx} className="flex items-center gap-1.5 truncate">
                                <span className="w-1 h-1 rounded-full bg-muted-soft flex-shrink-0" />
                                <span className="truncate">{typeof item === 'string' ? item : item.text}</span>
                            </li>
                        ))}
                        {itemCount > 3 && (
                            <li className="text-muted-soft pl-2.5">+{itemCount - 3} more</li>
                        )}
                    </ul>
                )}
            </div>
        );
    };

    const renderListEdit = () => {
        const items = data.items || [];
        return (
            <div className="space-y-2">
                <Input
                    size="sm"
                    value={data.title || ''}
                    onChange={(e) => handleFieldChange('title', e.target.value)}
                    placeholder="List title"
                    autoFocus
                />
                <textarea
                    value={items.map((i) => (typeof i === 'string' ? i : i.text)).join('\n')}
                    onChange={(e) => {
                        const newItems = e.target.value
                            .split('\n')
                            .filter(Boolean)
                            .map((text) => ({ text, checked: false }));
                        handleFieldChange('items', newItems);
                    }}
                    className={`${inlineFieldClasses} min-h-[80px] resize-none font-mono`}
                    placeholder="Items (one per line)"
                />
            </div>
        );
    };

    const renderCompleteCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-ink-soft">
                {data.completed === false ? 'Mark as not done' : 'Mark as completed'}
            </p>
            <p className="text-xs text-muted">Task ID: {data.id}</p>
        </div>
    );

    const renderDeleteCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-ink-soft">
                Delete {draft.entity_type}
            </p>
            <p className="text-xs text-muted">
                {draft.entity_type.charAt(0).toUpperCase() + draft.entity_type.slice(1)} ID: {data.id}
            </p>
        </div>
    );

    const renderAddToListCard = () => {
        const items = data.new_items || [];
        return (
            <div className="space-y-2">
                <p className="text-sm text-ink-soft">
                    Add {items.length} item{items.length !== 1 ? 's' : ''} to list (ID: {data.id})
                </p>
                {items.length > 0 && (
                    <ul className="text-xs text-muted space-y-0.5">
                        {items.slice(0, 5).map((item, idx) => (
                            <li key={idx} className="flex items-center gap-1.5 truncate">
                                <span className="w-1 h-1 rounded-full bg-muted-soft flex-shrink-0" />
                                <span className="truncate">{typeof item === 'string' ? item : item.text}</span>
                            </li>
                        ))}
                        {items.length > 5 && (
                            <li className="text-muted-soft pl-2.5">+{items.length - 5} more</li>
                        )}
                    </ul>
                )}
            </div>
        );
    };

    const renderUpdateListItemCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-ink-soft">
                Edit item [{data.item_index}] in list (ID: {data.list_id})
            </p>
            {data.text && <p className="text-xs text-muted">New text: &ldquo;{data.text}&rdquo;</p>}
            {data.checked !== undefined && (
                <p className="text-xs text-muted">{data.checked ? 'Mark as done' : 'Mark as undone'}</p>
            )}
        </div>
    );

    const renderRemoveListItemCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-ink-soft">
                Remove item [{data.item_index}] from list (ID: {data.list_id})
            </p>
        </div>
    );

    const renderUpdateFolderCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-ink-soft">
                Rename folder (ID: {data.id}) to &ldquo;{data.name}&rdquo;
            </p>
        </div>
    );

    const renderPreviewContent = () => {
        switch (draft.action_type) {
            case 'COMPLETE_TODO':
                return renderCompleteCard();
            case 'DELETE_TODO':
            case 'DELETE_NOTE':
            case 'DELETE_LIST':
            case 'DELETE_FOLDER':
                return renderDeleteCard();
            case 'ADD_TO_LIST':
                return renderAddToListCard();
            case 'UPDATE_LIST_ITEM':
                return renderUpdateListItemCard();
            case 'REMOVE_LIST_ITEM':
                return renderRemoveListItemCard();
            case 'UPDATE_FOLDER':
                return renderUpdateFolderCard();
            default:
                break;
        }

        switch (draft.entity_type) {
            case 'todo':
                return isInlineEditing ? renderTaskEdit() : renderTaskPreview();
            case 'note':
                return isInlineEditing ? renderNoteEdit() : renderNotePreview();
            case 'list':
                return isInlineEditing ? renderListEdit() : renderListPreview();
            default:
                return <p className="text-sm text-muted">Unknown entity type</p>;
        }
    };

    const showEditButton = ![
        'COMPLETE_TODO',
        'DELETE_TODO',
        'DELETE_NOTE',
        'DELETE_LIST',
        'DELETE_FOLDER',
        'REMOVE_LIST_ITEM',
    ].includes(draft.action_type);

    return (
        <div className="bg-surface border border-border rounded-xl p-4 space-y-3">
            {/* Header — eyebrow only, no icon tile. */}
            <Eyebrow>{actionLabel}</Eyebrow>

            {/* Body */}
            <div>{renderPreviewContent()}</div>

            {/* Actions */}
            <div className="flex gap-2 pt-1">
                <Button
                    variant="primary"
                    size="sm"
                    onClick={handleConfirm}
                    disabled={isProcessing}
                >
                    <Check size={14} strokeWidth={1.75} aria-hidden="true" />
                    Confirm
                </Button>
                {showEditButton && (
                    <Button
                        variant="secondary"
                        size="sm"
                        onClick={handleEdit}
                        disabled={isProcessing}
                    >
                        <Pencil size={14} strokeWidth={1.75} aria-hidden="true" />
                        {isInlineEditing ? 'Done' : 'Edit'}
                    </Button>
                )}
                <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => onReject(draft.id)}
                    disabled={isProcessing}
                >
                    <X size={14} strokeWidth={1.75} aria-hidden="true" />
                    Cancel
                </Button>
            </div>
        </div>
    );
}
