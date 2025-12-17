import { useState } from 'react';
import { Check, X, Pencil, Calendar, Tag, FileText, ListTodo, StickyNote, Hash } from 'lucide-react';

const entityIcons = {
    todo: ListTodo,
    note: StickyNote,
    list: FileText
};

const actionLabels = {
    CREATE_TODO: 'New Task',
    CREATE_NOTE: 'New Note',
    CREATE_LIST: 'New List',
    UPDATE_TODO: 'Update Task',
    UPDATE_NOTE: 'Update Note',
    UPDATE_LIST: 'Update List',
    COMPLETE_TODO: 'Complete Task',
    ADD_TO_LIST: 'Add to List',
    UPDATE_LIST_ITEM: 'Update List Item',
    REMOVE_LIST_ITEM: 'Remove List Item',
    UPDATE_FOLDER: 'Update Folder',
    DELETE_TODO: 'Delete Task',
    DELETE_NOTE: 'Delete Note',
    DELETE_LIST: 'Delete List',
    DELETE_FOLDER: 'Delete Folder'
};

export default function DraftPreviewCard({ draft, onConfirm, onReject, onEdit, isProcessing }) {
    const [isInlineEditing, setIsInlineEditing] = useState(false);
    const [editedData, setEditedData] = useState(draft.data || draft.draft_data);

    const Icon = entityIcons[draft.entity_type] || FileText;
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
        setEditedData(prev => ({ ...prev, [field]: value }));
    };

    const handleEdit = () => {
        if (isInlineEditing) {
            // Already in inline editing mode - just exit (changes are preserved in editedData)
            setIsInlineEditing(false);
        } else if (onEdit) {
            // Open widget UI prefilled with draft data
            onEdit(draft);
        } else {
            // Fallback to inline editing
            setIsInlineEditing(true);
        }
    };

    // Task Card: title, due date, tag
    const renderTaskCard = () => (
        <div className="space-y-2">
            {isInlineEditing ? (
                <div className="space-y-2">
                    <input
                        type="text"
                        value={data.title || ''}
                        onChange={(e) => handleFieldChange('title', e.target.value)}
                        className="w-full px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200 focus:border-indigo-400"
                        placeholder="Task title"
                        autoFocus
                    />
                    <div className="flex gap-2">
                        <input
                            type="datetime-local"
                            value={data.due_date ? data.due_date.slice(0, 16) : ''}
                            onChange={(e) => handleFieldChange('due_date', e.target.value ? new Date(e.target.value).toISOString() : null)}
                            className="flex-1 px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        />
                        <input
                            type="text"
                            value={data.tag || ''}
                            onChange={(e) => handleFieldChange('tag', e.target.value)}
                            className="w-28 px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200"
                            placeholder="Tag"
                        />
                    </div>
                </div>
            ) : (
                <>
                    <p className="font-medium text-slate-800 text-sm">{data.title}</p>
                    <div className="flex flex-wrap items-center gap-2 text-xs">
                        {data.due_date && (
                            <span className="inline-flex items-center gap-1 px-2 py-0.5 bg-amber-50 text-amber-700 rounded-full">
                                <Calendar className="w-3 h-3" />
                                {new Date(data.due_date).toLocaleDateString('en-US', {
                                    month: 'short',
                                    day: 'numeric',
                                    hour: 'numeric',
                                    minute: '2-digit'
                                })}
                            </span>
                        )}
                        {data.tag && (
                            <span className="inline-flex items-center gap-1 px-2 py-0.5 bg-indigo-50 text-indigo-600 rounded-full">
                                <Tag className="w-3 h-3" />
                                {data.tag}
                            </span>
                        )}
                    </div>
                </>
            )}
        </div>
    );

    // Note Card: title, first ~140 chars of content
    const renderNoteCard = () => (
        <div className="space-y-2">
            {isInlineEditing ? (
                <div className="space-y-2">
                    <input
                        type="text"
                        value={data.title || ''}
                        onChange={(e) => handleFieldChange('title', e.target.value)}
                        className="w-full px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200 focus:border-indigo-400"
                        placeholder="Note title"
                        autoFocus
                    />
                    <textarea
                        value={data.content || ''}
                        onChange={(e) => handleFieldChange('content', e.target.value)}
                        className="w-full px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200 min-h-[80px] resize-none"
                        placeholder="Note content"
                    />
                </div>
            ) : (
                <>
                    <p className="font-medium text-slate-800 text-sm">{data.title}</p>
                    {data.content && (
                        <p className="text-xs text-slate-500 leading-relaxed">
                            {data.content.length > 140
                                ? `${data.content.slice(0, 140)}...`
                                : data.content}
                        </p>
                    )}
                </>
            )}
        </div>
    );

    // List Card: title + item count
    const renderListCard = () => {
        const items = data.items || [];
        const itemCount = items.length;

        return (
            <div className="space-y-2">
                {isInlineEditing ? (
                    <div className="space-y-2">
                        <input
                            type="text"
                            value={data.title || ''}
                            onChange={(e) => handleFieldChange('title', e.target.value)}
                            className="w-full px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200 focus:border-indigo-400"
                            placeholder="List title"
                            autoFocus
                        />
                        <textarea
                            value={items.map(i => typeof i === 'string' ? i : i.text).join('\n')}
                            onChange={(e) => {
                                const newItems = e.target.value.split('\n').filter(Boolean).map(text => ({ text, checked: false }));
                                handleFieldChange('items', newItems);
                            }}
                            className="w-full px-2 py-1.5 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-200 min-h-[80px] resize-none font-mono"
                            placeholder="Items (one per line)"
                        />
                    </div>
                ) : (
                    <>
                        <div className="flex items-center justify-between">
                            <p className="font-medium text-slate-800 text-sm">{data.title}</p>
                            <span className="inline-flex items-center gap-1 px-2 py-0.5 bg-slate-100 text-slate-600 rounded-full text-xs">
                                <Hash className="w-3 h-3" />
                                {itemCount} {itemCount === 1 ? 'item' : 'items'}
                            </span>
                        </div>
                        {itemCount > 0 && (
                            <ul className="text-xs text-slate-500 space-y-0.5">
                                {items.slice(0, 3).map((item, idx) => (
                                    <li key={idx} className="flex items-center gap-1.5 truncate">
                                        <span className="w-1 h-1 rounded-full bg-slate-300 flex-shrink-0" />
                                        <span className="truncate">{typeof item === 'string' ? item : item.text}</span>
                                    </li>
                                ))}
                                {itemCount > 3 && (
                                    <li className="text-slate-400 pl-2.5">+{itemCount - 3} more</li>
                                )}
                            </ul>
                        )}
                    </>
                )}
            </div>
        );
    };

    // Render for COMPLETE_TODO action
    const renderCompleteCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-slate-600">
                {data.completed ? 'Mark as completed' : 'Mark as incomplete'}
            </p>
            <p className="text-xs text-slate-400">Task ID: {data.id}</p>
        </div>
    );

    // Render for DELETE actions
    const renderDeleteCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-slate-600">
                Delete {draft.entity_type}
            </p>
            <p className="text-xs text-slate-400">{draft.entity_type.charAt(0).toUpperCase() + draft.entity_type.slice(1)} ID: {data.id}</p>
        </div>
    );

    // Render for ADD_TO_LIST action
    const renderAddToListCard = () => {
        const items = data.new_items || [];
        return (
            <div className="space-y-2">
                <p className="text-sm text-slate-600">Add {items.length} item{items.length !== 1 ? 's' : ''} to list (ID: {data.id})</p>
                {items.length > 0 && (
                    <ul className="text-xs text-slate-500 space-y-0.5">
                        {items.slice(0, 5).map((item, idx) => (
                            <li key={idx} className="flex items-center gap-1.5 truncate">
                                <span className="w-1 h-1 rounded-full bg-slate-300 flex-shrink-0" />
                                <span className="truncate">{typeof item === 'string' ? item : item.text}</span>
                            </li>
                        ))}
                        {items.length > 5 && (
                            <li className="text-slate-400 pl-2.5">+{items.length - 5} more</li>
                        )}
                    </ul>
                )}
            </div>
        );
    };

    // Render for UPDATE_LIST_ITEM action
    const renderUpdateListItemCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-slate-600">
                Edit item [{data.item_index}] in list (ID: {data.list_id})
            </p>
            {data.text && <p className="text-xs text-slate-500">New text: "{data.text}"</p>}
            {data.checked !== undefined && (
                <p className="text-xs text-slate-500">{data.checked ? 'Mark as done' : 'Mark as undone'}</p>
            )}
        </div>
    );

    // Render for REMOVE_LIST_ITEM action
    const renderRemoveListItemCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-slate-600">
                Remove item [{data.item_index}] from list (ID: {data.list_id})
            </p>
        </div>
    );

    // Render for UPDATE_FOLDER action
    const renderUpdateFolderCard = () => (
        <div className="space-y-1">
            <p className="text-sm text-slate-600">
                Rename folder (ID: {data.id}) to "{data.name}"
            </p>
        </div>
    );

    const renderPreviewContent = () => {
        // Handle action-specific rendering first
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

        // Fall back to entity-type rendering for CREATE and UPDATE operations
        switch (draft.entity_type) {
            case 'todo':
                return renderTaskCard();
            case 'note':
                return renderNoteCard();
            case 'list':
                return renderListCard();
            default:
                return <p className="text-sm text-slate-500">Unknown entity type</p>;
        }
    };

    // Determine if the Edit button should be shown
    const showEditButton = ![
        'COMPLETE_TODO',
        'DELETE_TODO',
        'DELETE_NOTE',
        'DELETE_LIST',
        'DELETE_FOLDER',
        'REMOVE_LIST_ITEM'
    ].includes(draft.action_type);

    return (
        <div className="bg-white border border-slate-200 rounded-xl p-3 shadow-sm hover:shadow-md transition-shadow">
            {/* Header */}
            <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                    <div className="p-1.5 bg-indigo-50 rounded-lg">
                        <Icon className="w-3.5 h-3.5 text-indigo-600" />
                    </div>
                    <span className="text-xs font-medium text-indigo-600">{actionLabel}</span>
                </div>
            </div>

            {/* Content Preview */}
            <div className="mb-3">
                {renderPreviewContent()}
            </div>

            {/* Action Buttons - Confirm, Edit (optional), Cancel */}
            <div className="flex gap-2">
                <button
                    onClick={handleConfirm}
                    disabled={isProcessing}
                    className="flex-1 flex items-center justify-center gap-1.5 px-3 py-1.5 bg-emerald-500 hover:bg-emerald-600 text-white text-xs font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                    <Check className="w-3.5 h-3.5" />
                    Confirm
                </button>
                {showEditButton && (
                    <button
                        onClick={handleEdit}
                        disabled={isProcessing}
                        className="flex items-center justify-center gap-1.5 px-3 py-1.5 bg-indigo-50 hover:bg-indigo-100 text-indigo-600 text-xs font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        <Pencil className="w-3.5 h-3.5" />
                        {isInlineEditing ? 'Done' : 'Edit'}
                    </button>
                )}
                <button
                    onClick={() => onReject(draft.id)}
                    disabled={isProcessing}
                    className="flex items-center justify-center gap-1.5 px-3 py-1.5 bg-slate-100 hover:bg-slate-200 text-slate-600 text-xs font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                    <X className="w-3.5 h-3.5" />
                    Cancel
                </button>
            </div>
        </div>
    );
}
