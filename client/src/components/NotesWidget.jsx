import { useState, useEffect, useRef, forwardRef, useImperativeHandle } from 'react';
import Card from './Card';
import Input from './Input';
import Button from './Button';
import { getNotes, createNote, updateNote, deleteNote, getNoteFolders, createNoteFolder, updateNoteFolder, deleteNoteFolder } from '../services/api';
import { Plus, Trash2, Loader2, Save, Folder, FolderOpen, ChevronRight, ChevronLeft, Edit2, Inbox } from 'lucide-react';

const NotesWidget = forwardRef(function NotesWidget({ fullHeight = false, maxHeightPx = null, initialFolderId = null }, ref) {
    const [folders, setFolders] = useState([]);
    const [notes, setNotes] = useState([]);
    const [loading, setLoading] = useState(true);
    // Honour initialFolderId from props (used by Activity timeline deep-link).
    // Coerced to a number when numeric, since folder ids are integers.
    const [selectedFolderId, setSelectedFolderId] = useState(() => {
        if (initialFolderId == null) return null;
        const asNumber = Number(initialFolderId);
        return Number.isFinite(asNumber) ? asNumber : initialFolderId;
    });
    const [currentNote, setCurrentNote] = useState(null); // null = list view, object = edit view
    const [newFolderName, setNewFolderName] = useState('');
    const [editingFolderId, setEditingFolderId] = useState(null);
    const [editingFolderName, setEditingFolderName] = useState('');
    const editFolderInputRef = useRef(null);

    // Mobile view state: 'notes' or 'folders'
    const [mobileView, setMobileView] = useState('notes');

    // Mobile detection - moved here to avoid re-renders
    const [isMobileView, setIsMobileView] = useState(false);

    useEffect(() => {
        const checkMobile = () => setIsMobileView(window.innerWidth < 768);
        checkMobile();
        window.addEventListener('resize', checkMobile);
        return () => window.removeEventListener('resize', checkMobile);
    }, []);

    // Inline editing state for notes
    const [inlineEditingNoteId, setInlineEditingNoteId] = useState(null);
    const [inlineEditingField, setInlineEditingField] = useState(null); // 'title' or 'content'
    const [inlineEditValue, setInlineEditValue] = useState('');
    const inlineEditRef = useRef(null);

    useEffect(() => {
        fetchFolders();
    }, []);

    useEffect(() => {
        if (selectedFolderId !== null) {
            fetchNotes(selectedFolderId);
        }
    }, [selectedFolderId]);

    // Expose refresh method to parent via ref
    useImperativeHandle(ref, () => ({
        refresh: () => {
            fetchFolders();
            if (selectedFolderId !== null) {
                fetchNotes(selectedFolderId);
            }
        },
        selectFolder: (id) => {
            const next = id == null ? 'all' : (Number.isFinite(Number(id)) ? Number(id) : id);
            setSelectedFolderId(next);
        },
    }));

    const fetchFolders = async () => {
        try {
            const { data } = await getNoteFolders();
            const foldersArray = Array.isArray(data) ? data : [];
            setFolders(foldersArray);
            // Default to "All Notes" so unfiled notes are visible.
            // If a deep-link supplied a starting folder, honour it instead.
            if (selectedFolderId === null) {
                setSelectedFolderId('all');
            }
        } catch (error) {
            console.error('Error fetching folders:', error);
            setFolders([]);
        } finally {
            setLoading(false);
        }
    };

    const fetchNotes = async (folderId) => {
        try {
            // 'all' = no filter, fetch every note (incl. unfiled)
            const { data } = await getNotes(folderId === 'all' ? undefined : folderId);
            setNotes(Array.isArray(data) ? data : []);
        } catch (error) {
            console.error('Error fetching notes:', error);
            setNotes([]);
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
        if (selectedFolderId === null) return;
        // 'all' selected = create unfiled note (folder_id null)
        const folderForNew = selectedFolderId === 'all' ? null : selectedFolderId;
        setCurrentNote({ title: '', content: '', folder_id: folderForNew, isNew: true });
    };

    const handleEditNote = (note) => {
        setCurrentNote({ ...note, isNew: false });
    };

    const handleSaveNote = async (e) => {
        e.preventDefault();
        if (!currentNote.title && !currentNote.content) return;

        try {
            if (currentNote.isNew) {
                const folderForCreate = selectedFolderId === 'all' ? null : selectedFolderId;
                const { data } = await createNote(currentNote.title, currentNote.content, folderForCreate);
                setNotes([data, ...notes]);
            } else {
                const folderForUpdate = selectedFolderId === 'all' ? currentNote.folder_id : selectedFolderId;
                const { data } = await updateNote(currentNote.id, currentNote.title, currentNote.content, folderForUpdate);
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
            const folderForInline = selectedFolderId === 'all' ? notes.find(n => n.id === noteId)?.folder_id ?? null : selectedFolderId;
            await updateNote(noteId, updatedTitle, updatedContent, folderForInline);
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
                hideTitle={fullHeight}
                className={`flex flex-col min-h-0 flex-1 ${fullHeight ? 'h-full' : ''}`}
                actions={
                    <Button onClick={() => setCurrentNote(null)} variant="secondary" className="!px-3 !py-1 text-sm">
                        <ChevronRight size={16} className="rotate-180" /> Back
                    </Button>
                }
            >
                {/* Mobile: Back button when title is hidden */}
                {fullHeight && (
                    <div className="flex items-center justify-between mb-4 md:hidden">
                        <Button onClick={() => setCurrentNote(null)} variant="secondary" className="!px-3 !py-1 text-sm">
                            <ChevronLeft size={16} /> Back
                        </Button>
                        <span className="text-sm font-medium text-ink-soft">
                            {currentNote.isNew ? 'New Note' : 'Edit Note'}
                        </span>
                        <div className="w-16" /> {/* Spacer for centering */}
                    </div>
                )}
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
                        className="flex-1 w-full p-4 rounded-xl border border-border bg-surface/50 focus:bg-surface focus:border-[--color-accent] focus:ring-2 focus:ring-[--color-accent-ring]/20 transition-all duration-200 outline-none resize-none text-ink-soft font-normal leading-relaxed"
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

    // Handle folder selection on mobile - switch to notes view
    const handleMobileFolderSelect = (folderId) => {
        if (folderId === 'all' || editingFolderId !== folderId) {
            setSelectedFolderId(folderId);
            setMobileView('notes');
        }
    };

    // Render folders panel content - returns a flex container for proper scrolling
    const renderFoldersPanel = (isMobile) => (
        <div className={`flex flex-col ${isMobile ? 'h-full overflow-hidden' : 'flex-1 min-h-0'}`}>
            {isMobile && (
                <div className="flex items-center justify-between mb-4 flex-shrink-0">
                    <h3 className="text-sm font-semibold text-ink-soft">Folders</h3>
                    <button
                        onClick={() => setMobileView('notes')}
                        className="flex items-center gap-1 text-sm text-[--color-accent] hover:text-[--color-accent]"
                    >
                        Notes <ChevronRight size={16} />
                    </button>
                </div>
            )}
            <form onSubmit={handleCreateFolder} className="flex gap-2 mb-3 flex-shrink-0">
                <Input
                    value={newFolderName}
                    onChange={(e) => setNewFolderName(e.target.value)}
                    placeholder="New folder..."
                    className="!py-1.5 text-sm"
                />
                <Button
                    type="submit"
                    variant="primary"
                    className="!px-2 !py-1.5"
                    disabled={!newFolderName.trim()}
                    title={newFolderName.trim() ? 'Add folder' : 'Type a folder name first'}
                >
                    <Plus size={16} />
                </Button>
            </form>

            <div className="overflow-y-auto custom-scrollbar space-y-1 flex-1 min-h-0 pr-1">
                {/* All Notes virtual folder — shows every note including unfiled */}
                <div
                    onClick={() => isMobile ? handleMobileFolderSelect('all') : setSelectedFolderId('all')}
                    className={`group flex items-center justify-between p-2 rounded-lg cursor-pointer transition-all ${
                        selectedFolderId === 'all'
                            ? 'bg-[--color-accent-soft] border border-[--color-accent]'
                            : 'hover:bg-paper-2'
                    }`}
                >
                    <div className="flex items-center gap-2 flex-1 min-w-0">
                        <Inbox size={16} strokeWidth={1.75} className={selectedFolderId === 'all' ? 'text-[--color-accent] flex-shrink-0' : 'text-muted-soft flex-shrink-0'} />
                        <span className="text-sm font-medium text-ink-soft truncate">All Notes</span>
                    </div>
                </div>
                {folders.length === 0 ? null : (
                    folders.map((folder) => (
                        <div
                            key={folder.id}
                            onClick={() => isMobile ? handleMobileFolderSelect(folder.id) : (editingFolderId !== folder.id && setSelectedFolderId(folder.id))}
                            className={`group flex items-center justify-between p-2 rounded-lg cursor-pointer transition-all ${
                                selectedFolderId === folder.id
                                    ? 'bg-[--color-accent-soft] border border-[--color-accent]'
                                    : 'hover:bg-paper-2'
                            }`}
                        >
                            <div className="flex items-center gap-2 flex-1 min-w-0">
                                {selectedFolderId === folder.id ? (
                                    <FolderOpen size={16} className="text-[--color-accent] flex-shrink-0" />
                                ) : (
                                    <Folder size={16} className="text-muted-soft flex-shrink-0" />
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
                                        className="flex-1 text-sm bg-surface border border-[--color-accent] rounded px-2 py-0.5 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring]"
                                        autoFocus
                                    />
                                ) : (
                                    <span
                                        onClick={(e) => { e.stopPropagation(); startEditFolder(e, folder); }}
                                        className="text-sm font-medium text-ink-soft truncate cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
                                        title="Click to edit"
                                    >
                                        {folder.name}
                                    </span>
                                )}
                            </div>
                            <button
                                onClick={(e) => handleDeleteFolder(e, folder.id)}
                                className="text-muted-soft hover:text-danger transition-all p-1 cursor-pointer opacity-0 group-hover:opacity-100"
                            >
                                <Trash2 size={14} />
                            </button>
                        </div>
                    ))
                )}
            </div>
        </div>
    );

    // Render notes panel content - returns a flex container for proper scrolling
    const renderNotesPanel = (isMobile) => (
        <div className={`flex flex-col ${isMobile ? 'h-full overflow-hidden' : 'flex-1 min-h-0'}`}>
            {/* Mobile: Always show header with Folders button */}
            {isMobile && (
                <div className="flex justify-between items-center mb-3 flex-shrink-0">
                    <button
                        onClick={() => setMobileView('folders')}
                        className="flex items-center gap-1 text-sm text-[--color-accent] hover:text-[--color-accent]"
                    >
                        <ChevronLeft size={16} /> Folders
                    </button>
                    {selectedFolderId && (
                        <Button onClick={handleCreateNote} variant="primary" className="!px-2 !py-1.5">
                            <Plus size={16} />
                        </Button>
                    )}
                </div>
            )}
            {selectedFolderId ? (
                <>
                    {/* Desktop: Just the add button */}
                    {!isMobile && (
                        <div className="flex justify-end mb-3 flex-shrink-0">
                            <Button onClick={handleCreateNote} variant="primary" className="!px-2 !py-1.5">
                                <Plus size={16} />
                            </Button>
                        </div>
                    )}

                    <div className="overflow-y-auto custom-scrollbar space-y-2 flex-1 min-h-0 pr-1">
                        {notes.length === 0 ? (
                            <div className="flex-1 flex items-center justify-center h-full min-h-[120px]">
                                <span className="text-muted-soft text-sm">No Notes</span>
                            </div>
                        ) : (
                            notes.map((note) => (
                                <div
                                    key={note.id}
                                    data-activity-id={note.id}
                                    className="group p-3 bg-paper-2 hover:bg-surface rounded-xl border border-transparent hover:border-[--color-accent-soft] hover:shadow-md transition-all relative"
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
                                            className="w-full font-semibold text-ink text-sm bg-surface border border-[--color-accent] rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] pr-8"
                                            placeholder="Note title..."
                                            autoFocus
                                        />
                                    ) : (
                                        <h3
                                            onClick={(e) => startInlineEdit(e, note, 'title')}
                                            className="font-semibold text-ink text-sm truncate pr-8 cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
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
                                            className="w-full text-xs text-muted bg-surface border border-[--color-accent] rounded px-2 py-1 mt-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] resize-none"
                                            rows={3}
                                            placeholder="Note content..."
                                            autoFocus
                                        />
                                    ) : (
                                        <p
                                            onClick={(e) => startInlineEdit(e, note, 'content')}
                                            className="text-xs text-muted line-clamp-2 mt-1 cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
                                            title="Click to edit content"
                                        >
                                            {note.content || 'No content'}
                                        </p>
                                    )}

                                    <div className="flex items-center justify-between mt-2">
                                        <span className="text-xs text-muted-soft">
                                            {formatDate(note.updated_at)}
                                        </span>
                                        <div className="flex gap-1">
                                            <button
                                                onClick={() => handleEditNote(note)}
                                                className="text-muted-soft hover:text-[--color-accent] transition-all p-1 cursor-pointer"
                                                title="Open full editor"
                                            >
                                                <Edit2 size={14} />
                                            </button>
                                            <button
                                                onClick={(e) => handleDeleteNote(e, note.id)}
                                                className="text-muted-soft hover:text-danger transition-all p-1 cursor-pointer"
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
                <div className="flex-1 flex flex-col items-center justify-center text-muted-soft text-sm gap-2 min-h-[120px]">
                    <span>No Notes</span>
                </div>
            )}
        </div>
    );

    // Determine height: fullHeight uses h-full, maxHeightPx uses inline style (desktop only), otherwise max-h-[515px]
    // On mobile, always use max-h-[515px] even if maxHeightPx is provided
    const useMaxHeightPx = maxHeightPx && !fullHeight && !isMobileView;
    const heightClass = fullHeight ? 'h-full' : (useMaxHeightPx ? '' : 'max-h-[515px]');
    const cardStyle = useMaxHeightPx ? { height: maxHeightPx } : {};

    return (
        <Card
            title="Notes"
            hideTitle={fullHeight}
            className={`flex flex-col ${heightClass}`}
            style={cardStyle}
        >
            <div className="flex flex-col flex-1 min-h-0 overflow-hidden">
                {loading ? (
                    <div className="flex justify-center items-center py-10 text-[--color-accent]">
                        <Loader2 className="animate-spin" />
                    </div>
                ) : (
                    <>
                        {/* Desktop View - Two columns side by side */}
                        <div className="hidden md:flex gap-4 flex-1 min-h-0">
                            <div className="w-1/3 border-r border-divider pr-4 flex flex-col min-h-0">
                                <form onSubmit={handleCreateFolder} className="flex gap-2 mb-3 flex-shrink-0">
                                    <Input
                                        value={newFolderName}
                                        onChange={(e) => setNewFolderName(e.target.value)}
                                        placeholder="New folder..."
                                        className="!py-1.5 text-sm"
                                    />
                                    <Button
                                        type="submit"
                                        variant="primary"
                                        className="!px-2 !py-1.5"
                                        disabled={!newFolderName.trim()}
                                        title={newFolderName.trim() ? 'Add folder' : 'Type a folder name first'}
                                    >
                                        <Plus size={16} />
                                    </Button>
                                </form>
                                <div className="overflow-y-auto custom-scrollbar space-y-1 pr-1 flex-1 min-h-0">
                                    {/* All Notes virtual folder */}
                                    <div
                                        onClick={() => setSelectedFolderId('all')}
                                        className={`group flex items-center justify-between p-2 rounded-lg cursor-pointer transition-all ${
                                            selectedFolderId === 'all'
                                                ? 'bg-[--color-accent-soft] border border-[--color-accent]'
                                                : 'hover:bg-paper-2'
                                        }`}
                                    >
                                        <div className="flex items-center gap-2 flex-1 min-w-0">
                                            <Inbox size={16} strokeWidth={1.75} className={selectedFolderId === 'all' ? 'text-[--color-accent] flex-shrink-0' : 'text-muted-soft flex-shrink-0'} />
                                            <span className="text-sm font-medium text-ink-soft truncate">All Notes</span>
                                        </div>
                                    </div>
                                    {folders.length === 0 ? null : (
                                        folders.map((folder) => (
                                            <div
                                                key={folder.id}
                                                onClick={() => editingFolderId !== folder.id && setSelectedFolderId(folder.id)}
                                                className={`group flex items-center justify-between p-2 rounded-lg cursor-pointer transition-all ${
                                                    selectedFolderId === folder.id
                                                        ? 'bg-[--color-accent-soft] border border-[--color-accent]'
                                                        : 'hover:bg-paper-2'
                                                }`}
                                            >
                                                <div className="flex items-center gap-2 flex-1 min-w-0">
                                                    {selectedFolderId === folder.id ? (
                                                        <FolderOpen size={16} className="text-[--color-accent] flex-shrink-0" />
                                                    ) : (
                                                        <Folder size={16} className="text-muted-soft flex-shrink-0" />
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
                                                            className="flex-1 text-sm bg-surface border border-[--color-accent] rounded px-2 py-0.5 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring]"
                                                            autoFocus
                                                        />
                                                    ) : (
                                                        <span
                                                            onClick={(e) => { e.stopPropagation(); startEditFolder(e, folder); }}
                                                            className="text-sm font-medium text-ink-soft truncate cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
                                                            title="Click to edit"
                                                        >
                                                            {folder.name}
                                                        </span>
                                                    )}
                                                </div>
                                                <button
                                                    onClick={(e) => handleDeleteFolder(e, folder.id)}
                                                    className="text-muted-soft hover:text-danger transition-all p-1 cursor-pointer opacity-0 group-hover:opacity-100"
                                                >
                                                    <Trash2 size={14} />
                                                </button>
                                            </div>
                                        ))
                                    )}
                                </div>
                            </div>
                            <div className="w-2/3 flex flex-col min-h-0">
                                {selectedFolderId ? (
                                    <>
                                        <div className="flex justify-end mb-3 flex-shrink-0">
                                            <Button onClick={handleCreateNote} variant="primary" className="!px-2 !py-1.5">
                                                <Plus size={16} />
                                            </Button>
                                        </div>
                                        <div className="overflow-y-auto custom-scrollbar space-y-2 pr-1 flex-1 min-h-0">
                                            {notes.length === 0 ? (
                                                <div className="flex-1 flex items-center justify-center h-full min-h-[120px]">
                                                    <span className="text-muted-soft text-sm">No Notes</span>
                                                </div>
                                            ) : (
                                                notes.map((note) => (
                                                    <div
                                                        key={note.id}
                                                        className="group p-3 bg-paper-2 hover:bg-surface rounded-xl border border-transparent hover:border-[--color-accent-soft] hover:shadow-md transition-all relative"
                                                    >
                                                        {inlineEditingNoteId === note.id && inlineEditingField === 'title' ? (
                                                            <input
                                                                ref={inlineEditRef}
                                                                type="text"
                                                                value={inlineEditValue}
                                                                onChange={(e) => setInlineEditValue(e.target.value)}
                                                                onBlur={() => saveInlineEdit(note.id)}
                                                                onKeyDown={(e) => {
                                                                    if (e.key === 'Enter') { e.preventDefault(); saveInlineEdit(note.id); }
                                                                    else if (e.key === 'Escape') { cancelInlineEdit(); }
                                                                }}
                                                                className="w-full font-semibold text-ink text-sm bg-surface border border-[--color-accent] rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] pr-8"
                                                                placeholder="Note title..."
                                                                autoFocus
                                                            />
                                                        ) : (
                                                            <h3
                                                                onClick={(e) => startInlineEdit(e, note, 'title')}
                                                                className="font-semibold text-ink text-sm truncate pr-8 cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
                                                                title="Click to edit title"
                                                            >
                                                                {note.title || 'Untitled Note'}
                                                            </h3>
                                                        )}
                                                        {inlineEditingNoteId === note.id && inlineEditingField === 'content' ? (
                                                            <textarea
                                                                ref={inlineEditRef}
                                                                value={inlineEditValue}
                                                                onChange={(e) => setInlineEditValue(e.target.value)}
                                                                onBlur={() => saveInlineEdit(note.id)}
                                                                onKeyDown={(e) => { if (e.key === 'Escape') { cancelInlineEdit(); } }}
                                                                className="w-full text-xs text-muted bg-surface border border-[--color-accent] rounded px-2 py-1 mt-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] resize-none"
                                                                rows={3}
                                                                placeholder="Note content..."
                                                                autoFocus
                                                            />
                                                        ) : (
                                                            <p
                                                                onClick={(e) => startInlineEdit(e, note, 'content')}
                                                                className="text-xs text-muted line-clamp-2 mt-1 cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1"
                                                                title="Click to edit content"
                                                            >
                                                                {note.content || 'No content'}
                                                            </p>
                                                        )}
                                                        <div className="flex items-center justify-between mt-2">
                                                            <span className="text-xs text-muted-soft">{formatDate(note.updated_at)}</span>
                                                            <div className="flex gap-1">
                                                                <button onClick={() => handleEditNote(note)} className="text-muted-soft hover:text-[--color-accent] transition-all p-1 cursor-pointer" title="Open full editor">
                                                                    <Edit2 size={14} />
                                                                </button>
                                                                <button onClick={(e) => handleDeleteNote(e, note.id)} className="text-muted-soft hover:text-danger transition-all p-1 cursor-pointer" title="Delete">
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
                                    <div className="flex-1 flex flex-col items-center justify-center text-muted-soft text-sm gap-2 min-h-[120px]">
                                        <span>No Notes</span>
                                    </div>
                                )}
                            </div>
                        </div>

                        {/* Mobile View - Single panel (no sliding, just show one at a time) */}
                        <div className="md:hidden flex flex-col flex-1 min-h-0">
                            {mobileView === 'notes' ? (
                                renderNotesPanel(true)
                            ) : (
                                renderFoldersPanel(true)
                            )}
                        </div>
                    </>
                )}
            </div>
        </Card>
    );
});

export default NotesWidget;
