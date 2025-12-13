import { useState, useEffect, useRef } from 'react';
import Card from './Card';
import Input from './Input';
import Button from './Button';
import { getNotes, createNote, updateNote, deleteNote, getNoteFolders, createNoteFolder, updateNoteFolder, deleteNoteFolder } from '../services/api';
import { Plus, Trash2, Loader2, Save, Folder, FolderOpen, ChevronRight, Edit2 } from 'lucide-react';

export default function NotesWidget({ fullHeight = false, maxHeight = null, maxHeightPx = null }) {
    const [folders, setFolders] = useState([]);
    const [notes, setNotes] = useState([]);
    const [loading, setLoading] = useState(true);
    const [selectedFolderId, setSelectedFolderId] = useState(null);
    const [currentNote, setCurrentNote] = useState(null); // null = list view, object = edit view
    const [newFolderName, setNewFolderName] = useState('');
    const [editingFolderId, setEditingFolderId] = useState(null);
    const [editingFolderName, setEditingFolderName] = useState('');
    const editFolderInputRef = useRef(null);

    // Inline editing state for notes
    const [inlineEditingNoteId, setInlineEditingNoteId] = useState(null);
    const [inlineEditingField, setInlineEditingField] = useState(null); // 'title' or 'content'
    const [inlineEditValue, setInlineEditValue] = useState('');
    const inlineEditRef = useRef(null);

    useEffect(() => {
        fetchFolders();
    }, []);

    useEffect(() => {
        if (selectedFolderId) {
            fetchNotes(selectedFolderId);
        }
    }, [selectedFolderId]);

    const fetchFolders = async () => {
        try {
            const { data } = await getNoteFolders();
            setFolders(data);
            // Auto-select first folder if available
            if (data.length > 0 && !selectedFolderId) {
                setSelectedFolderId(data[0].id);
            }
        } catch (error) {
            console.error('Error fetching folders:', error);
        } finally {
            setLoading(false);
        }
    };

    const fetchNotes = async (folderId) => {
        try {
            const { data } = await getNotes(folderId);
            setNotes(data);
        } catch (error) {
            console.error('Error fetching notes:', error);
        }
    };

    // Folder functions
    const handleCreateFolder = async (e) => {
        e.preventDefault();
        if (!newFolderName.trim()) return;

        try {
            const { data } = await createNoteFolder(newFolderName);
            setFolders([data, ...folders]);
            setNewFolderName('');
            setSelectedFolderId(data.id);
        } catch (error) {
            console.error('Error creating folder:', error);
        }
    };

    const startEditFolder = (e, folder) => {
        e.stopPropagation();
        setEditingFolderId(folder.id);
        setEditingFolderName(folder.name);
        setTimeout(() => editFolderInputRef.current?.focus(), 0);
    };

    const saveEditFolder = async (folderId) => {
        if (!editingFolderName.trim()) {
            setEditingFolderId(null);
            return;
        }

        try {
            await updateNoteFolder(folderId, editingFolderName.trim());
            setFolders(folders.map(f => f.id === folderId ? { ...f, name: editingFolderName.trim() } : f));
            setEditingFolderId(null);
        } catch (error) {
            console.error('Error updating folder:', error);
            fetchFolders();
        }
    };

    const handleDeleteFolder = async (e, id) => {
        e.stopPropagation();
        if (!window.confirm('Delete this folder and all its notes?')) return;

        setFolders(folders.filter(f => f.id !== id));
        if (selectedFolderId === id) {
            setSelectedFolderId(folders.find(f => f.id !== id)?.id || null);
            setNotes([]);
        }

        try {
            await deleteNoteFolder(id);
        } catch {
            fetchFolders();
        }
    };

    // Note functions
    const handleCreateNote = () => {
        if (!selectedFolderId) return;
        setCurrentNote({ title: '', content: '', folder_id: selectedFolderId, isNew: true });
    };

    const handleEditNote = (note) => {
        setCurrentNote({ ...note, isNew: false });
    };

    const handleSaveNote = async (e) => {
        e.preventDefault();
        if (!currentNote.title && !currentNote.content) return;

        try {
            if (currentNote.isNew) {
                const { data } = await createNote(currentNote.title, currentNote.content, selectedFolderId);
                setNotes([data, ...notes]);
            } else {
                const { data } = await updateNote(currentNote.id, currentNote.title, currentNote.content, selectedFolderId);
                // Move updated note to top (most recently updated first)
                setNotes([data, ...notes.filter(n => n.id !== data.id)]);
            }
            setCurrentNote(null);
        } catch (error) {
            console.error('Error saving note:', error);
        }
    };

    const handleDeleteNote = async (e, id) => {
        e.stopPropagation();
        if (!window.confirm('Delete this note?')) return;

        setNotes(notes.filter(n => n.id !== id));
        try {
            await deleteNote(id);
        } catch {
            fetchNotes(selectedFolderId);
        }
    };

    // Inline editing functions
    const startInlineEdit = (e, note, field) => {
        e.stopPropagation();
        setInlineEditingNoteId(note.id);
        setInlineEditingField(field);
        setInlineEditValue(field === 'title' ? (note.title || '') : (note.content || ''));
        setTimeout(() => inlineEditRef.current?.focus(), 0);
    };

    const saveInlineEdit = async (noteId) => {
        const note = notes.find(n => n.id === noteId);
        if (!note) {
            cancelInlineEdit();
            return;
        }

        const field = inlineEditingField;
        const newValue = inlineEditValue;

        // Check if value actually changed
        const oldValue = field === 'title' ? (note.title || '') : (note.content || '');
        if (newValue === oldValue) {
            cancelInlineEdit();
            return;
        }

        const updatedTitle = field === 'title' ? newValue : note.title;
        const updatedContent = field === 'content' ? newValue : note.content;

        // Optimistic update - move to top since it's being updated
        const updatedNote = { ...note, title: updatedTitle, content: updatedContent, updated_at: new Date().toISOString() };
        setNotes([updatedNote, ...notes.filter(n => n.id !== noteId)]);
        cancelInlineEdit();

        try {
            await updateNote(noteId, updatedTitle, updatedContent, selectedFolderId);
        } catch (error) {
            console.error('Error updating note:', error);
            fetchNotes(selectedFolderId);
        }
    };

    const cancelInlineEdit = () => {
        setInlineEditingNoteId(null);
        setInlineEditingField(null);
        setInlineEditValue('');
    };

    const formatDate = (dateString) => {
        if (!dateString) return '';
        const date = new Date(dateString);
        return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    };

    // Edit view
    if (currentNote) {
        return (
            <Card
                title={currentNote.isNew ? 'New Note' : 'Edit Note'}
                className="flex flex-col min-h-0 flex-1"
                actions={
                    <Button onClick={() => setCurrentNote(null)} variant="secondary" className="!px-3 !py-1 text-sm">
                        <ChevronRight size={16} className="rotate-180" /> Back
                    </Button>
                }
            >
                <form onSubmit={handleSaveNote} className="flex-1 flex flex-col gap-4">
                    <Input
                        value={currentNote.title}
                        onChange={(e) => setCurrentNote({ ...currentNote, title: e.target.value })}
                        placeholder="Note Title"
                        className="font-semibold text-lg"
                    />
                    <textarea
                        value={currentNote.content}
                        onChange={(e) => setCurrentNote({ ...currentNote, content: e.target.value })}
                        placeholder="Write your note here..."
                        className="flex-1 w-full p-4 rounded-xl border border-gray-200 bg-white/50 focus:bg-white focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500/20 transition-all duration-200 outline-none resize-none text-gray-700 font-normal leading-relaxed"
                    />
                    <div className="flex justify-end">
                        <Button type="submit" variant="primary">
                            <Save size={18} /> Save Note
                        </Button>
                    </div>
                </form>
            </Card>
        );
    }

    // Two-column list view
    const cardStyle = maxHeightPx ? { height: maxHeightPx } : {};

    return (
        <Card title="Notes" className={`flex flex-col ${fullHeight ? 'h-full' : ''} ${maxHeight ? maxHeight : ''}`} style={cardStyle}>
            <div className={`flex flex-col ${fullHeight || maxHeight || maxHeightPx ? 'flex-1 min-h-0' : ''}`}>
                {loading ? (
                    <div className="flex justify-center items-center py-10 text-indigo-500">
                        <Loader2 className="animate-spin" />
                    </div>
                ) : (
                    <div className="flex gap-4 overflow-hidden flex-1 min-h-0">
                        {/* Left Column - Folders */}
                        <div className="w-1/3 flex flex-col overflow-hidden border-r border-slate-100 pr-4">
                            <form onSubmit={handleCreateFolder} className="flex gap-2 mb-3">
                                <Input
                                    value={newFolderName}
                                    onChange={(e) => setNewFolderName(e.target.value)}
                                    placeholder="New folder..."
                                    className="!py-1.5 text-sm"
                                />
                                <Button type="submit" variant="primary" className="!px-2 !py-1.5">
                                    <Plus size={16} />
                                </Button>
                            </form>

                            <div className="overflow-y-auto custom-scrollbar space-y-1 flex-1 min-h-0">
                                {folders.length === 0 ? (
                                    <div className="text-center text-gray-400 text-sm mt-4">No folders yet.</div>
                                ) : (
                                    folders.map((folder) => (
                                        <div
                                            key={folder.id}
                                            onClick={() => editingFolderId !== folder.id && setSelectedFolderId(folder.id)}
                                            className={`group flex items-center justify-between p-2 rounded-lg cursor-pointer transition-all ${
                                                selectedFolderId === folder.id
                                                    ? 'bg-indigo-50 border border-indigo-200'
                                                    : 'hover:bg-slate-50'
                                            }`}
                                        >
                                            <div className="flex items-center gap-2 flex-1 min-w-0">
                                                {selectedFolderId === folder.id ? (
                                                    <FolderOpen size={16} className="text-indigo-500 flex-shrink-0" />
                                                ) : (
                                                    <Folder size={16} className="text-slate-400 flex-shrink-0" />
                                                )}
                                                {editingFolderId === folder.id ? (
                                                    <input
                                                        ref={editFolderInputRef}
                                                        type="text"
                                                        value={editingFolderName}
                                                        onChange={(e) => setEditingFolderName(e.target.value)}
                                                        onBlur={() => saveEditFolder(folder.id)}
                                                        onKeyDown={(e) => {
                                                            if (e.key === 'Enter') saveEditFolder(folder.id);
                                                            if (e.key === 'Escape') setEditingFolderId(null);
                                                        }}
                                                        onClick={(e) => e.stopPropagation()}
                                                        className="flex-1 text-sm bg-white border border-indigo-300 rounded px-2 py-0.5 focus:outline-none focus:ring-2 focus:ring-indigo-500"
                                                        autoFocus
                                                    />
                                                ) : (
                                                    <span
                                                        onClick={(e) => { e.stopPropagation(); startEditFolder(e, folder); }}
                                                        className="text-sm font-medium text-gray-700 truncate cursor-pointer hover:bg-slate-100 rounded px-1 -mx-1"
                                                        title="Click to edit"
                                                    >
                                                        {folder.name}
                                                    </span>
                                                )}
                                            </div>
                                            <button
                                                onClick={(e) => handleDeleteFolder(e, folder.id)}
                                                className="text-slate-400 hover:text-rose-500 transition-all p-1 cursor-pointer opacity-0 group-hover:opacity-100"
                                            >
                                                <Trash2 size={14} />
                                            </button>
                                        </div>
                                    ))
                                )}
                            </div>
                        </div>

                        {/* Right Column - Notes */}
                        <div className="w-2/3 flex flex-col overflow-hidden">
                            {selectedFolderId ? (
                                <>
                                    <div className="flex justify-end mb-3">
                                        <Button onClick={handleCreateNote} variant="primary" className="!px-2 !py-1.5">
                                            <Plus size={16} />
                                        </Button>
                                    </div>

                                    <div className="overflow-y-auto custom-scrollbar space-y-2 flex-1 min-h-0">
                                        {notes.length === 0 ? (
                                            <div className="text-center text-gray-400 text-sm mt-4">No notes in this folder.</div>
                                        ) : (
                                            notes.map((note) => (
                                                <div
                                                    key={note.id}
                                                    className="group p-3 bg-slate-50 hover:bg-white rounded-xl border border-transparent hover:border-indigo-100 hover:shadow-md transition-all relative"
                                                >
                                                    {/* Title - inline editable */}
                                                    {inlineEditingNoteId === note.id && inlineEditingField === 'title' ? (
                                                        <input
                                                            ref={inlineEditRef}
                                                            type="text"
                                                            value={inlineEditValue}
                                                            onChange={(e) => setInlineEditValue(e.target.value)}
                                                            onBlur={() => saveInlineEdit(note.id)}
                                                            onKeyDown={(e) => {
                                                                if (e.key === 'Enter') {
                                                                    e.preventDefault();
                                                                    saveInlineEdit(note.id);
                                                                } else if (e.key === 'Escape') {
                                                                    cancelInlineEdit();
                                                                }
                                                            }}
                                                            className="w-full font-semibold text-gray-800 text-sm bg-white border border-indigo-300 rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-indigo-500 pr-8"
                                                            placeholder="Note title..."
                                                            autoFocus
                                                        />
                                                    ) : (
                                                        <h3
                                                            onClick={(e) => startInlineEdit(e, note, 'title')}
                                                            className="font-semibold text-gray-800 text-sm truncate pr-8 cursor-pointer hover:bg-slate-100 rounded px-1 -mx-1"
                                                            title="Click to edit title"
                                                        >
                                                            {note.title || 'Untitled Note'}
                                                        </h3>
                                                    )}

                                                    {/* Content - inline editable */}
                                                    {inlineEditingNoteId === note.id && inlineEditingField === 'content' ? (
                                                        <textarea
                                                            ref={inlineEditRef}
                                                            value={inlineEditValue}
                                                            onChange={(e) => setInlineEditValue(e.target.value)}
                                                            onBlur={() => saveInlineEdit(note.id)}
                                                            onKeyDown={(e) => {
                                                                if (e.key === 'Escape') {
                                                                    cancelInlineEdit();
                                                                }
                                                            }}
                                                            className="w-full text-xs text-gray-500 bg-white border border-indigo-300 rounded px-2 py-1 mt-1 focus:outline-none focus:ring-2 focus:ring-indigo-500 resize-none"
                                                            rows={3}
                                                            placeholder="Note content..."
                                                            autoFocus
                                                        />
                                                    ) : (
                                                        <p
                                                            onClick={(e) => startInlineEdit(e, note, 'content')}
                                                            className="text-xs text-gray-500 line-clamp-2 mt-1 cursor-pointer hover:bg-slate-100 rounded px-1 -mx-1"
                                                            title="Click to edit content"
                                                        >
                                                            {note.content || 'No content'}
                                                        </p>
                                                    )}

                                                    <div className="flex items-center justify-between mt-2">
                                                        <span className="text-xs text-gray-400">
                                                            {formatDate(note.updated_at)}
                                                        </span>
                                                        <div className="flex gap-1">
                                                            <button
                                                                onClick={() => handleEditNote(note)}
                                                                className="text-slate-400 hover:text-indigo-500 transition-all p-1 cursor-pointer"
                                                                title="Open full editor"
                                                            >
                                                                <Edit2 size={14} />
                                                            </button>
                                                            <button
                                                                onClick={(e) => handleDeleteNote(e, note.id)}
                                                                className="text-slate-400 hover:text-rose-500 transition-all p-1 cursor-pointer"
                                                                title="Delete"
                                                            >
                                                                <Trash2 size={14} />
                                                            </button>
                                                        </div>
                                                    </div>
                                                </div>
                                            ))
                                        )}
                                    </div>
                                </>
                            ) : (
                                <div className="flex-1 flex items-center justify-center text-gray-400 text-sm">
                                    {folders.length === 0 ? 'Create a folder to get started' : 'Select a folder'}
                                </div>
                            )}
                        </div>
                    </div>
                )}
            </div>
        </Card>
    );
}
