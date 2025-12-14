import { useState, useEffect, useRef } from 'react';
import Card from './Card';
import Input from './Input';
import Button from './Button';
import { getLists, createList, updateList, deleteList } from '../services/api';
import { Plus, Trash2, Loader2, Check, ChevronRight, ChevronDown, Edit2 } from 'lucide-react';

export default function ListsWidget({ fullHeight = false }) {
    const [lists, setLists] = useState([]);
    const [loading, setLoading] = useState(true);
    const [expandedListIds, setExpandedListIds] = useState(new Set());
    const [newListName, setNewListName] = useState('');
    const [newItemText, setNewItemText] = useState({});
    const [editingItemKey, setEditingItemKey] = useState(null); // "listId-itemIndex"
    const [editingItemText, setEditingItemText] = useState('');
    const [editingListId, setEditingListId] = useState(null);
    const [editingListTitle, setEditingListTitle] = useState('');
    const editItemInputRef = useRef(null);
    const editListInputRef = useRef(null);

    useEffect(() => {
        fetchLists();
    }, []);

    const fetchLists = async () => {
        try {
            const { data } = await getLists();
            // Ensure items is parsed if it comes as string (though pg usually parses jsonb)
            const dataArray = Array.isArray(data) ? data : [];
            const parsed = dataArray.map(l => ({
                ...l,
                items: typeof l.items === 'string' ? JSON.parse(l.items) : l.items
            }));
            setLists(parsed);
        } catch (error) {
            console.error('Error fetching lists:', error);
            setLists([]);
        } finally {
            setLoading(false);
        }
    };

    const handleCreateList = async (e) => {
        e.preventDefault();
        if (!newListName.trim()) return;
        try {
            const { data } = await createList(newListName, []);
            const parsed = { ...data, items: [] };
            setLists([parsed, ...lists]);
            setNewListName('');
        } catch (error) {
            console.error('Error creating list:', error);
        }
    };

    const handleDeleteList = async (e, id) => {
        e.stopPropagation();
        if (!window.confirm('Delete this list?')) return;
        setLists(lists.filter(l => l.id !== id));
        try {
            await deleteList(id);
        } catch {
            fetchLists();
        }
    };

    const toggleExpand = (listId) => {
        setExpandedListIds(prev => {
            if (prev.has(listId)) {
                // Collapse if already expanded
                return new Set();
            } else {
                // Expand only this one, collapse others
                return new Set([listId]);
            }
        });
    };

    const handleAddItem = async (e, listId) => {
        e.preventDefault();
        const itemText = newItemText[listId]?.trim();
        if (!itemText) return;

        const list = lists.find(l => l.id === listId);
        if (!list) return;

        const updatedItems = [...list.items, { text: itemText, completed: false }];
        const updatedList = { ...list, items: updatedItems };

        // Optimistic
        setLists(lists.map(l => l.id === listId ? updatedList : l));
        setNewItemText(prev => ({ ...prev, [listId]: '' }));

        try {
            await updateList(listId, list.title, updatedItems);
        } catch (error) {
            console.error('Error adding item:', error);
            fetchLists();
        }
    };

    const toggleItem = async (listId, index) => {
        const list = lists.find(l => l.id === listId);
        if (!list) return;

        const updatedItems = [...list.items];
        updatedItems[index].completed = !updatedItems[index].completed;

        const updatedList = { ...list, items: updatedItems };
        setLists(lists.map(l => l.id === listId ? updatedList : l));

        try {
            await updateList(listId, list.title, updatedItems);
        } catch {
            fetchLists();
        }
    };

    const deleteItem = async (listId, index) => {
        const list = lists.find(l => l.id === listId);
        if (!list) return;

        const updatedItems = list.items.filter((_, i) => i !== index);

        const updatedList = { ...list, items: updatedItems };
        setLists(lists.map(l => l.id === listId ? updatedList : l));

        try {
            await updateList(listId, list.title, updatedItems);
        } catch {
            fetchLists();
        }
    };

    // Edit item text
    const startEditItem = (listId, index, text) => {
        setEditingItemKey(`${listId}-${index}`);
        setEditingItemText(text);
        setTimeout(() => editItemInputRef.current?.focus(), 0);
    };

    const saveEditItem = async (listId, index) => {
        if (!editingItemText.trim()) {
            setEditingItemKey(null);
            return;
        }

        const list = lists.find(l => l.id === listId);
        if (!list) return;

        const updatedItems = [...list.items];
        updatedItems[index].text = editingItemText.trim();

        const updatedList = { ...list, items: updatedItems };
        setLists(lists.map(l => l.id === listId ? updatedList : l));
        setEditingItemKey(null);

        try {
            await updateList(listId, list.title, updatedItems);
        } catch {
            fetchLists();
        }
    };

    // Edit list title
    const startEditListTitle = (e, list) => {
        e.stopPropagation();
        setEditingListId(list.id);
        setEditingListTitle(list.title);
        setTimeout(() => editListInputRef.current?.focus(), 0);
    };

    const saveEditListTitle = async (listId) => {
        if (!editingListTitle.trim()) {
            setEditingListId(null);
            return;
        }

        const list = lists.find(l => l.id === listId);
        if (!list) return;

        const updatedList = { ...list, title: editingListTitle.trim() };
        setLists(lists.map(l => l.id === listId ? updatedList : l));
        setEditingListId(null);

        try {
            await updateList(listId, editingListTitle.trim(), list.items);
        } catch {
            fetchLists();
        }
    };

    return (
        <Card
            title="Lists"
            hideTitle={fullHeight}
            className={`flex flex-col ${fullHeight ? 'h-full' : 'max-h-[515px]'}`}
        >
            <div className="flex flex-col flex-1 min-h-0">
                {loading ? (
                    <div className="flex justify-center items-center py-10 text-indigo-500">
                        <Loader2 className="animate-spin" />
                    </div>
                ) : (
                    <>
                        <form onSubmit={handleCreateList} className="flex gap-2 mb-4">
                            <Input
                                value={newListName}
                                onChange={(e) => setNewListName(e.target.value)}
                                placeholder="New List Name..."
                            />
                            <Button type="submit" variant="primary" className="!px-3">
                                <Plus size={20} />
                            </Button>
                        </form>
                        <div className="overflow-y-auto custom-scrollbar space-y-2 pr-1 flex-1 min-h-0">
                            {lists.length === 0 ? (
                                <div className="text-center text-gray-400 mt-10">No lists created.</div>
                            ) : (
                                lists.map((list) => {
                                    const isExpanded = expandedListIds.has(list.id);
                                    return (
                                        <div key={list.id} className="rounded-xl border border-transparent hover:border-indigo-100 transition-all">
                                            {/* List Header */}
                                            <div
                                                onClick={() => editingListId !== list.id && toggleExpand(list.id)}
                                                className={`group flex items-center justify-between p-4 bg-slate-50 hover:bg-white cursor-pointer transition-all ${isExpanded ? 'rounded-t-xl' : 'rounded-xl'}`}
                                            >
                                                <div className="flex items-center gap-2 flex-1 min-w-0">
                                                    <button
                                                        onClick={(e) => { e.stopPropagation(); toggleExpand(list.id); }}
                                                        className="text-slate-400 hover:text-indigo-500 transition-colors cursor-pointer"
                                                    >
                                                        {isExpanded ? <ChevronDown size={18} /> : <ChevronRight size={18} />}
                                                    </button>
                                                    {editingListId === list.id ? (
                                                        <input
                                                            ref={editListInputRef}
                                                            type="text"
                                                            value={editingListTitle}
                                                            onChange={(e) => setEditingListTitle(e.target.value)}
                                                            onBlur={() => saveEditListTitle(list.id)}
                                                            onKeyDown={(e) => {
                                                                if (e.key === 'Enter') saveEditListTitle(list.id);
                                                                if (e.key === 'Escape') setEditingListId(null);
                                                            }}
                                                            onClick={(e) => e.stopPropagation()}
                                                            className="font-semibold text-gray-800 bg-white border border-indigo-300 rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-indigo-500 flex-1 mr-2"
                                                            autoFocus
                                                        />
                                                    ) : (
                                                        <span
                                                            onClick={(e) => { e.stopPropagation(); startEditListTitle(e, list); }}
                                                            className="font-semibold text-gray-800 cursor-pointer hover:bg-slate-100 rounded px-1 -mx-1 truncate"
                                                            title="Click to edit"
                                                        >
                                                            {list.title}
                                                        </span>
                                                    )}
                                                </div>
                                                <div className="flex items-center gap-2">
                                                    <span className="text-xs text-gray-500 bg-gray-200 px-2 py-1 rounded-full">
                                                        {list.items ? list.items.length : 0} items
                                                    </span>
                                                    <button
                                                        onClick={(e) => startEditListTitle(e, list)}
                                                        className="text-slate-400 hover:text-indigo-500 transition-colors p-1 cursor-pointer"
                                                        title="Edit"
                                                    >
                                                        <Edit2 size={16} />
                                                    </button>
                                                    <button
                                                        onClick={(e) => handleDeleteList(e, list.id)}
                                                        className="text-slate-400 hover:text-rose-500 transition-colors p-1 cursor-pointer"
                                                        title="Delete"
                                                    >
                                                        <Trash2 size={16} />
                                                    </button>
                                                </div>
                                            </div>

                                            {/* Expanded Items */}
                                            {isExpanded && (
                                                <div className="bg-white rounded-b-xl border-t border-slate-100 p-3 pl-8">
                                                    {/* Add Item Form */}
                                                    <form onSubmit={(e) => handleAddItem(e, list.id)} className="flex gap-2 mb-3">
                                                        <Input
                                                            value={newItemText[list.id] || ''}
                                                            onChange={(e) => setNewItemText(prev => ({ ...prev, [list.id]: e.target.value }))}
                                                            placeholder="Add item..."
                                                            className="!py-1.5 text-sm"
                                                        />
                                                        <Button type="submit" variant="primary" className="!px-2 !py-1.5">
                                                            <Plus size={16} />
                                                        </Button>
                                                    </form>

                                                    {/* Items List */}
                                                    <div className="space-y-1">
                                                        {list.items?.length === 0 ? (
                                                            <div className="text-center text-gray-400 py-2 text-sm">Empty list.</div>
                                                        ) : (
                                                            list.items.map((item, idx) => {
                                                                const itemKey = `${list.id}-${idx}`;
                                                                return (
                                                                    <div key={idx} className="group flex items-center justify-between p-2 hover:bg-slate-50 rounded-lg transition-all">
                                                                        <div className="flex items-center gap-3 min-w-0 flex-1">
                                                                            <button
                                                                                onClick={() => toggleItem(list.id, idx)}
                                                                                className={`flex-shrink-0 w-5 h-5 rounded-md border-2 flex items-center justify-center transition-all duration-200 cursor-pointer ${item.completed
                                                                                    ? 'bg-emerald-500 border-emerald-500 text-white'
                                                                                    : 'border-slate-300 hover:border-indigo-400'
                                                                                    }`}
                                                                            >
                                                                                {item.completed && <Check size={12} strokeWidth={3} />}
                                                                            </button>
                                                                            {editingItemKey === itemKey ? (
                                                                                <input
                                                                                    ref={editItemInputRef}
                                                                                    type="text"
                                                                                    value={editingItemText}
                                                                                    onChange={(e) => setEditingItemText(e.target.value)}
                                                                                    onBlur={() => saveEditItem(list.id, idx)}
                                                                                    onKeyDown={(e) => {
                                                                                        if (e.key === 'Enter') saveEditItem(list.id, idx);
                                                                                        if (e.key === 'Escape') setEditingItemKey(null);
                                                                                    }}
                                                                                    className="flex-1 min-w-0 text-gray-700 bg-white border border-indigo-300 rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-indigo-500 text-sm"
                                                                                    autoFocus
                                                                                />
                                                                            ) : (
                                                                                <span
                                                                                    onClick={() => startEditItem(list.id, idx, item.text)}
                                                                                    className={`truncate cursor-pointer hover:bg-slate-100 rounded px-1 -mx-1 text-sm ${item.completed ? 'text-gray-400 line-through' : 'text-gray-700'}`}
                                                                                    title="Click to edit"
                                                                                >
                                                                                    {item.text}
                                                                                </span>
                                                                            )}
                                                                        </div>
                                                                        <div className="flex gap-1">
                                                                            <button
                                                                                onClick={() => startEditItem(list.id, idx, item.text)}
                                                                                className="text-slate-400 hover:text-indigo-500 transition-colors p-1 cursor-pointer"
                                                                                title="Edit"
                                                                            >
                                                                                <Edit2 size={14} />
                                                                            </button>
                                                                            <button
                                                                                onClick={() => deleteItem(list.id, idx)}
                                                                                className="text-slate-400 hover:text-rose-500 transition-colors p-1 cursor-pointer"
                                                                                title="Delete"
                                                                            >
                                                                                <Trash2 size={14} />
                                                                            </button>
                                                                        </div>
                                                                    </div>
                                                                );
                                                            })
                                                        )}
                                                    </div>
                                                </div>
                                            )}
                                        </div>
                                    );
                                })
                            )}
                        </div>
                    </>
                )}
            </div>
        </Card>
    );
}
