import { useState, useEffect, useRef, forwardRef, useImperativeHandle } from 'react';
import { createPortal } from 'react-dom';
import Card from './Card';
import Input from './Input';
import Button from './Button';
import DateTimePicker from './DateTimePicker';
import { getTodos, createTodo, updateTodo, deleteTodo } from '../services/api';
import { Trash2, Plus, Check, Loader2, X, Tag as TagIcon, Edit2, ChevronDown, ChevronRight, Filter } from 'lucide-react';

const TodoWidget = forwardRef(function TodoWidget({ fullHeight = false }, ref) {
    const [todos, setTodos] = useState([]);
    const [loading, setLoading] = useState(true);
    const [isExpanded, setIsExpanded] = useState(false);
    const [isAddFormExpanded, setIsAddFormExpanded] = useState(false);
    const [editingId, setEditingId] = useState(null);
    const [editingTodo, setEditingTodo] = useState(null);
    const [popoverPosition, setPopoverPosition] = useState({ top: 0, left: 0 });
    const [showTagDropdown, setShowTagDropdown] = useState(false);
    const [tagDropdownPosition, setTagDropdownPosition] = useState({ top: 0, left: 0, width: 0 });
    const [customTagInput, setCustomTagInput] = useState('');
    const [isAddingCustomTag, setIsAddingCustomTag] = useState(false);
    const popoverRef = useRef(null);
    const tagDropdownRef = useRef(null);
    const tagButtonRef = useRef(null);
    const addInputRef = useRef(null);
    const [titleError, setTitleError] = useState('');
    const [inlineTagEditId, setInlineTagEditId] = useState(null);
    const [editTagDropdownPosition, setEditTagDropdownPosition] = useState({ top: 0, left: 0, width: 0 });
    const [showEditTagDropdown, setShowEditTagDropdown] = useState(false);
    const [inlineTitleEditId, setInlineTitleEditId] = useState(null);
    const [inlineDescEditId, setInlineDescEditId] = useState(null);
    const [inlineEditValue, setInlineEditValue] = useState('');
    const inlineTagDropdownRef = useRef(null);
    const editTagDropdownRef = useRef(null);
    const [filterTag, setFilterTag] = useState('');
    const [showFilterDropdown, setShowFilterDropdown] = useState(false);
    const [showCompleted, setShowCompleted] = useState(false);
    const filterDropdownRef = useRef(null);
    const [tooltipData, setTooltipData] = useState({ visible: false, text: '', x: 0, y: 0 });

    // Predefined tags
    const [predefinedTags] = useState(['Work', 'Personal', 'Urgent', 'Important']);

    // Form state for adding new todos
    const [formData, setFormData] = useState({
        title: '',
        description: '',
        due_date: '',
        tag: ''
    });

    // Separate form state for editing todos
    const [editFormData, setEditFormData] = useState({
        title: '',
        description: '',
        due_date: '',
        tag: ''
    });

    useEffect(() => {
        fetchTodos();
    }, []);

    // Expose refresh method to parent via ref
    useImperativeHandle(ref, () => ({
        refresh: () => fetchTodos()
    }));

    // Close popover when clicking outside or pressing ESC
    useEffect(() => {
        const handleClickOutside = (event) => {
            if (popoverRef.current && !popoverRef.current.contains(event.target) && editingId) {
                // Check if click is not on an edit button
                if (!event.target.closest('[data-edit-button]')) {
                    // Don't close if clicking inside MUI DateTimePicker popup
                    if (event.target.closest('.MuiPopper-root') || event.target.closest('.MuiPickersPopper-root') || event.target.closest('.MuiDialog-root')) {
                        return;
                    }
                    resetEditForm();
                }
            }

            // Close tag dropdown when clicking outside
            if (tagDropdownRef.current && !tagDropdownRef.current.contains(event.target)) {
                setShowTagDropdown(false);
                setIsAddingCustomTag(false);
                setCustomTagInput('');
            }

            // Close inline tag dropdown when clicking outside
            if (inlineTagDropdownRef.current && !inlineTagDropdownRef.current.contains(event.target)) {
                setInlineTagEditId(null);
            }

            // Close filter dropdown when clicking outside
            if (filterDropdownRef.current && !filterDropdownRef.current.contains(event.target)) {
                setShowFilterDropdown(false);
            }

            // Close edit tag dropdown when clicking outside
            if (editTagDropdownRef.current && !editTagDropdownRef.current.contains(event.target)) {
                setShowEditTagDropdown(false);
                setIsAddingCustomTag(false);
                setCustomTagInput('');
            }
        };

        const handleKeyDown = (event) => {
            if (event.key === 'Escape') {
                if (editingId) {
                    resetEditForm();
                } else if (isAddFormExpanded) {
                    resetForm();
                }
            }
            // Submit the form when Enter is pressed (only if form is already expanded)
            if (event.key === 'Enter' && !editingId && !showTagDropdown && isAddFormExpanded) {
                const tagName = event.target.tagName.toLowerCase();
                // If not in textarea (allow multiline) and not in custom tag input
                if (tagName !== 'textarea' && !event.target.closest('[data-custom-tag-input]')) {
                    event.preventDefault();
                    if (formData.title.trim()) {
                        // Submit if title is not empty
                        handleAdd(event);
                    } else {
                        // Show error if title is empty
                        setTitleError('Please enter a title for your task');
                        addInputRef.current?.focus();
                    }
                }
            }
        };

        document.addEventListener('mousedown', handleClickOutside);
        document.addEventListener('keydown', handleKeyDown);
        return () => {
            document.removeEventListener('mousedown', handleClickOutside);
            document.removeEventListener('keydown', handleKeyDown);
        };
    }, [editingId, isAddFormExpanded, showTagDropdown, formData.title]);

    const handleTagButtonClick = () => {
        if (!showTagDropdown && tagButtonRef.current) {
            const rect = tagButtonRef.current.getBoundingClientRect();
            // Use viewport coordinates directly since dropdown is position:fixed
            setTagDropdownPosition({
                top: rect.bottom,
                left: rect.left,
                width: rect.width
            });
        }
        setShowTagDropdown(!showTagDropdown);
    };

    const fetchTodos = async () => {
        try {
            const { data } = await getTodos();
            setTodos(Array.isArray(data) ? data : []);
        } catch (error) {
            console.error('Error fetching todos:', error);
            setTodos([]);
        } finally {
            setLoading(false);
        }
    };

    const resetForm = () => {
        setFormData({
            title: '',
            description: '',
            due_date: '',
            tag: ''
        });
        setIsAddFormExpanded(false);
        setShowTagDropdown(false);
        setIsAddingCustomTag(false);
        setCustomTagInput('');
        setTitleError('');
    };

    const resetEditForm = () => {
        setEditFormData({
            title: '',
            description: '',
            due_date: '',
            tag: ''
        });
        setEditingId(null);
        setEditingTodo(null);
        setShowEditTagDropdown(false);
        setIsAddingCustomTag(false);
        setCustomTagInput('');
    };

    const handleAdd = async (e) => {
        e.preventDefault();
        if (!formData.title.trim()) return;

        try {
            const todoData = {
                title: formData.title,
                description: formData.description || null,
                due_date: formData.due_date ? new Date(formData.due_date).toISOString() : null,
                tag: formData.tag || null
            };
            console.log('Creating todo with data:', todoData);
            const { data } = await createTodo(todoData);
            console.log('Todo created successfully:', data);
            setTodos([data, ...todos]);
            setIsAddFormExpanded(false);
            resetForm();
        } catch (error) {
            console.error('Error adding todo:', error);
        }
    };

    const handleEdit = (todo, buttonElement) => {
        const rect = buttonElement.getBoundingClientRect();

        // Popover dimensions
        const popoverWidth = 384; // w-96 = 384px
        const padding = 16;

        // Position to the left of the button, aligned with button's top
        let left = rect.right - popoverWidth;
        let top = rect.top;

        // If popover would go off left edge, align left edge with button
        if (left < padding) {
            left = padding;
        }

        // If popover would go off right edge
        if (left + popoverWidth > window.innerWidth - padding) {
            left = window.innerWidth - popoverWidth - padding;
        }

        // Keep top within viewport bounds (allow scrolling within popover)
        if (top < padding) {
            top = padding;
        }

        // Popover has max-h-[90vh]; clamp top so even at max height it fits.
        const viewportHeight = window.innerHeight;
        const maxPopoverHeight = viewportHeight * 0.9;
        if (top + maxPopoverHeight > viewportHeight - padding) {
            top = Math.max(padding, viewportHeight - maxPopoverHeight - padding);
        }

        setPopoverPosition({
            top,
            left
        });

        setEditingId(todo.id);
        setEditingTodo(todo);

        // Convert UTC timestamp to local datetime-local format
        let localDateTime = '';
        if (todo.due_date) {
            const date = new Date(todo.due_date);
            // Get local time components
            const year = date.getFullYear();
            const month = String(date.getMonth() + 1).padStart(2, '0');
            const day = String(date.getDate()).padStart(2, '0');
            const hours = String(date.getHours()).padStart(2, '0');
            const minutes = String(date.getMinutes()).padStart(2, '0');
            localDateTime = `${year}-${month}-${day}T${hours}:${minutes}`;
        }

        setEditFormData({
            title: todo.title || '',
            description: todo.description || '',
            due_date: localDateTime,
            tag: todo.tag || ''
        });
        console.log('Editing todo:', todo);
        console.log('Edit form data set to:', { title: todo.title, due_date: localDateTime, tag: todo.tag });
    };

    const handleUpdate = async (e) => {
        e.preventDefault();
        if (!editFormData.title.trim() || !editingId) return;

        try {
            // Convert datetime-local to ISO timestamp if present
            const updates = {
                title: editFormData.title,
                description: editFormData.description || null,
                due_date: editFormData.due_date ? new Date(editFormData.due_date).toISOString() : null,
                tag: editFormData.tag || null
            };
            console.log('Edit form data before conversion:', editFormData);
            console.log('Updating todo with data:', updates);
            const { data } = await updateTodo(editingId, updates);
            console.log('Todo updated successfully:', data);
            setTodos(todos.map(t => t.id === editingId ? data : t));
            resetEditForm();
        } catch (error) {
            console.error('Error updating todo:', error);
        }
    };

    const handleToggle = async (id, completed) => {
        // Optimistic update
        setTodos(todos.map(t => t.id === id ? { ...t, completed: !completed } : t));
        try {
            await updateTodo(id, { completed: !completed });
        } catch (error) {
            // Revert if failed
            console.error('Error updating todo:', error);
            fetchTodos();
        }
    };

    const handleDelete = async (id) => {
        // Optimistic update
        setTodos(todos.filter(t => t.id !== id));
        try {
            await deleteTodo(id);
        } catch (error) {
            console.error('Error deleting todo:', error);
            fetchTodos();
        }
    };

    const handleInlineDateChange = async (todoId, newDate) => {
        const todo = todos.find(t => t.id === todoId);
        if (!todo) return;

        const updates = {
            due_date: newDate ? new Date(newDate).toISOString() : null
        };

        // Optimistic update
        setTodos(todos.map(t => t.id === todoId ? { ...t, due_date: updates.due_date } : t));

        try {
            await updateTodo(todoId, updates);
        } catch (error) {
            console.error('Error updating todo date:', error);
            fetchTodos();
        }
    };

    const handleInlineTagChange = async (todoId, newTag) => {
        const todo = todos.find(t => t.id === todoId);
        if (!todo) return;

        const updates = {
            tag: newTag || null
        };

        // Optimistic update
        setTodos(todos.map(t => t.id === todoId ? { ...t, tag: updates.tag } : t));
        setInlineTagEditId(null);

        try {
            await updateTodo(todoId, updates);
        } catch (error) {
            console.error('Error updating todo tag:', error);
            fetchTodos();
        }
    };

    const handleInlineTitleChange = async (todoId, newTitle) => {
        if (!newTitle.trim()) {
            setInlineTitleEditId(null);
            setInlineEditValue('');
            return;
        }

        const todo = todos.find(t => t.id === todoId);
        if (!todo || todo.title === newTitle) {
            setInlineTitleEditId(null);
            setInlineEditValue('');
            return;
        }

        // Optimistic update
        setTodos(todos.map(t => t.id === todoId ? { ...t, title: newTitle } : t));
        setInlineTitleEditId(null);
        setInlineEditValue('');

        try {
            await updateTodo(todoId, { title: newTitle });
        } catch (error) {
            console.error('Error updating todo title:', error);
            fetchTodos();
        }
    };

    const handleInlineDescChange = async (todoId, newDesc) => {
        const todo = todos.find(t => t.id === todoId);
        if (!todo || todo.description === newDesc) {
            setInlineDescEditId(null);
            setInlineEditValue('');
            return;
        }

        // Optimistic update
        setTodos(todos.map(t => t.id === todoId ? { ...t, description: newDesc || null } : t));
        setInlineDescEditId(null);
        setInlineEditValue('');

        try {
            await updateTodo(todoId, { description: newDesc || null });
        } catch (error) {
            console.error('Error updating todo description:', error);
            fetchTodos();
        }
    };

    const formatDate = (dateString, isCompleted = false) => {
        if (!dateString) return null;
        const date = new Date(dateString);
        const now = new Date();

        // Reset time for day comparisons
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const dateDay = new Date(date.getFullYear(), date.getMonth(), date.getDate());

        const isToday = dateDay.getTime() === today.getTime();

        // Yesterday
        const yesterday = new Date(today);
        yesterday.setDate(today.getDate() - 1);
        const isYesterday = dateDay.getTime() === yesterday.getTime();

        // Last 7 days (excluding today and yesterday)
        const sevenDaysAgo = new Date(today);
        sevenDaysAgo.setDate(today.getDate() - 7);
        const isLastWeek = dateDay < yesterday && dateDay >= sevenDaysAgo;

        // This month
        const isThisMonth = dateDay < sevenDaysAgo &&
            date.getMonth() === now.getMonth() &&
            date.getFullYear() === now.getFullYear();

        // For completed todos, don't show overdue - use past date categories instead
        const isOverdue = !isCompleted && date < now && !isToday;

        return {
            formatted: date.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }),
            isOverdue,
            isToday,
            isYesterday,
            isLastWeek,
            isThisMonth
        };
    };

    const formatDateTimeDisplay = (dateString) => {
        if (!dateString) return 'Select Date';
        const date = new Date(dateString);
        return date.toLocaleString('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric',
            hour: 'numeric',
            minute: '2-digit',
            hour12: true
        });
    };

    const getDateCategory = (dateString) => {
        if (!dateString) return 'no-date';

        const dueDate = new Date(dateString);
        const now = new Date();

        // Reset time to start of day for comparison
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const dueDateDay = new Date(dueDate.getFullYear(), dueDate.getMonth(), dueDate.getDate());

        // Check if overdue (before today)
        if (dueDateDay < today) return 'overdue';

        // Check if today
        if (dueDateDay.getTime() === today.getTime()) return 'today';

        // Check if this week (within 7 days from today, excluding today)
        const weekFromNow = new Date(today);
        weekFromNow.setDate(today.getDate() + 7);

        if (dueDateDay < weekFromNow) return 'this-week';

        // Everything else is remaining
        return 'remaining';
    };

    const categorizeTodos = (todoList) => {
        const categories = {
            overdue: [],
            today: [],
            'this-week': [],
            remaining: [],
            'no-date': []
        };

        todoList.forEach(todo => {
            const category = getDateCategory(todo.due_date);
            categories[category].push(todo);
        });

        // Sort each category by due date (latest first), except no-date
        const sortByDueDate = (a, b) => {
            const dateA = new Date(a.due_date);
            const dateB = new Date(b.due_date);
            return dateB - dateA; // Latest first
        };

        categories.overdue.sort(sortByDueDate);
        categories.today.sort(sortByDueDate);
        categories['this-week'].sort(sortByDueDate);
        categories.remaining.sort(sortByDueDate);

        return categories;
    };

    const getCompletedDateCategory = (dateString) => {
        if (!dateString) return 'no-date';

        const date = new Date(dateString);
        const now = new Date();

        // Reset time to start of day for comparison
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const dateDay = new Date(date.getFullYear(), date.getMonth(), date.getDate());

        // Today
        if (dateDay.getTime() === today.getTime()) return 'today';

        // Tomorrow
        const tomorrow = new Date(today);
        tomorrow.setDate(today.getDate() + 1);
        if (dateDay.getTime() === tomorrow.getTime()) return 'tomorrow';

        // This week (within 7 days from today, excluding today and tomorrow)
        const weekFromNow = new Date(today);
        weekFromNow.setDate(today.getDate() + 7);
        if (dateDay > tomorrow && dateDay < weekFromNow) return 'this-week';

        // This month (rest of current month, excluding this week)
        const endOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0);
        if (dateDay >= weekFromNow && dateDay <= endOfMonth) return 'this-month';

        // This year (rest of current year, excluding this month)
        const endOfYear = new Date(now.getFullYear(), 11, 31);
        if (dateDay > endOfMonth && dateDay <= endOfYear) return 'this-year-future';

        // Next year
        const startOfNextYear = new Date(now.getFullYear() + 1, 0, 1);
        const endOfNextYear = new Date(now.getFullYear() + 1, 11, 31);
        if (dateDay >= startOfNextYear && dateDay <= endOfNextYear) return 'next-year';

        // Future (after next year)
        if (dateDay > endOfNextYear) return 'future';

        // Yesterday
        const yesterday = new Date(today);
        yesterday.setDate(today.getDate() - 1);
        if (dateDay.getTime() === yesterday.getTime()) return 'yesterday';

        // Last 7 days (excluding today and yesterday)
        const sevenDaysAgo = new Date(today);
        sevenDaysAgo.setDate(today.getDate() - 7);
        if (dateDay >= sevenDaysAgo && dateDay < yesterday) return 'last-7-days';

        // Last 30 days (excluding last 7 days)
        const thirtyDaysAgo = new Date(today);
        thirtyDaysAgo.setDate(today.getDate() - 30);
        if (dateDay >= thirtyDaysAgo && dateDay < sevenDaysAgo) return 'last-30-days';

        // This year past (earlier this year, excluding last 30 days)
        const startOfYear = new Date(now.getFullYear(), 0, 1);
        if (dateDay >= startOfYear && dateDay < thirtyDaysAgo) return 'this-year-past';

        // Last year
        const startOfLastYear = new Date(now.getFullYear() - 1, 0, 1);
        const endOfLastYear = new Date(now.getFullYear() - 1, 11, 31);
        if (dateDay >= startOfLastYear && dateDay <= endOfLastYear) return 'last-year';

        // Past (before last year)
        return 'past';
    };

    const categorizeCompletedTodos = (todoList) => {
        const categories = {
            'today': [],
            'tomorrow': [],
            'this-week': [],
            'this-month': [],
            'this-year-future': [],
            'next-year': [],
            'future': [],
            'yesterday': [],
            'last-7-days': [],
            'last-30-days': [],
            'this-year-past': [],
            'last-year': [],
            'past': [],
            'no-date': []
        };

        todoList.forEach(todo => {
            const category = getCompletedDateCategory(todo.due_date);
            categories[category].push(todo);
        });

        // Sort each category by due date (most recent first)
        const sortByDueDate = (a, b) => {
            const dateA = new Date(a.due_date);
            const dateB = new Date(b.due_date);
            return dateB - dateA;
        };

        Object.keys(categories).forEach(key => {
            if (key !== 'no-date') {
                categories[key].sort(sortByDueDate);
            }
        });

        return categories;
    };

    const getTagColor = (tag) => {
        if (!tag) return '';
        const colors = {
            work: 'bg-paper-2 text-ink-soft border-border',
            personal: 'bg-purple-100 text-purple-700 border-purple-200',
            urgent: 'bg-danger-soft text-danger border-danger',
            important: 'bg-orange-100 text-orange-700 border-orange-200',
        };
        return colors[tag.toLowerCase()] || 'bg-paper-2 text-ink-soft border-border';
    };

    const handleTagSelect = (tag) => {
        console.log('Tag selected:', tag);
        setFormData({ ...formData, tag });
        setShowTagDropdown(false);
        setIsAddingCustomTag(false);
        setCustomTagInput('');
    };

    const handleAddCustomTag = () => {
        if (customTagInput.trim()) {
            setFormData({ ...formData, tag: customTagInput.trim() });
            setShowTagDropdown(false);
            setIsAddingCustomTag(false);
            setCustomTagInput('');
        }
    };

    const renderTodoItem = (todo) => {
        const dateInfo = formatDate(todo.due_date, todo.completed);

        return (
            <div
                key={todo.id}
                data-activity-id={todo.id}
                className="group flex items-start gap-3 p-3 rounded-lg hover:bg-paper-2 border border-transparent hover:border-divider transition-all duration-200"
            >
                <button
                    onClick={() => handleToggle(todo.id, todo.completed)}
                    className={`flex-shrink-0 w-6 h-6 rounded-full border-2 flex items-center justify-center transition-all duration-200 mt-0.5 ${todo.completed
                        ? 'bg-success border-success text-white'
                        : 'border-border-strong hover:border-[--color-accent]'
                        }`}
                >
                    {todo.completed && <Check size={14} strokeWidth={3} />}
                </button>

                <div className="flex-1 min-w-0">
                    <div className="flex items-start justify-between gap-2">
                        <div className="flex-1 min-w-0">
                            {/* Title row with tag and date */}
                            <div className="flex items-center gap-2 flex-nowrap">
                                {/* Title - clickable to edit */}
                                {inlineTitleEditId === todo.id ? (
                                    <input
                                        type="text"
                                        value={inlineEditValue}
                                        onChange={(e) => setInlineEditValue(e.target.value)}
                                        onBlur={() => handleInlineTitleChange(todo.id, inlineEditValue)}
                                        onKeyDown={(e) => {
                                            if (e.key === 'Enter') {
                                                e.preventDefault();
                                                handleInlineTitleChange(todo.id, inlineEditValue);
                                            } else if (e.key === 'Escape') {
                                                setInlineTitleEditId(null);
                                                setInlineEditValue('');
                                            }
                                        }}
                                        className="flex-1 min-w-0 font-medium text-ink bg-surface border border-[--color-accent] rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring]"
                                        autoFocus
                                    />
                                ) : (
                                    <h3
                                        onClick={() => {
                                            setInlineTitleEditId(todo.id);
                                            setInlineDescEditId(null);
                                            setInlineEditValue(todo.title);
                                        }}
                                        onMouseEnter={(e) => {
                                            const rect = e.currentTarget.getBoundingClientRect();
                                            setTooltipData({
                                                visible: true,
                                                text: todo.title,
                                                x: rect.left,
                                                y: rect.bottom + 4
                                            });
                                        }}
                                        onMouseLeave={() => setTooltipData({ ...tooltipData, visible: false })}
                                        className={`font-medium cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1 truncate max-w-[300px] ${todo.completed ? 'text-muted-soft line-through' : 'text-ink'}`}
                                    >
                                        {todo.title}
                                    </h3>
                                )}

                                {/* Tag - only show if exists */}
                                {todo.tag && (
                                    <div className="relative" ref={inlineTagEditId === todo.id ? inlineTagDropdownRef : null}>
                                        <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border cursor-pointer hover:opacity-80 ${getTagColor(todo.tag)}`}
                                            onClick={() => {
                                                setInlineTagEditId(todo.id);
                                            }}
                                            title="Click to change tag"
                                        >
                                            <TagIcon size={10} />
                                            {todo.tag}
                                        </span>
                                        {inlineTagEditId === todo.id && (
                                            <div className="absolute top-full left-0 mt-1 z-[100] bg-surface border border-border rounded-lg shadow-lg min-w-40">
                                                <div className="p-1">
                                                    <button
                                                        type="button"
                                                        onClick={() => handleInlineTagChange(todo.id, '')}
                                                        className="w-full text-left px-3 py-1.5 text-xs rounded hover:bg-paper-2 transition-colors text-muted"
                                                    >
                                                        None
                                                    </button>
                                                    {predefinedTags.map((tag) => (
                                                        <button
                                                            key={tag}
                                                            type="button"
                                                            onClick={() => handleInlineTagChange(todo.id, tag)}
                                                            className="w-full text-left px-3 py-1.5 text-xs rounded hover:bg-paper-2 transition-colors flex items-center gap-2"
                                                        >
                                                            <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border ${getTagColor(tag)}`}>
                                                                <TagIcon size={10} />
                                                                {tag}
                                                            </span>
                                                        </button>
                                                    ))}
                                                </div>
                                            </div>
                                        )}
                                    </div>
                                )}

                            </div>

                            {/* Description - only show if exists */}
                            {(todo.description || inlineDescEditId === todo.id) && (
                                inlineDescEditId === todo.id ? (
                                    <textarea
                                        value={inlineEditValue}
                                        onChange={(e) => setInlineEditValue(e.target.value)}
                                        onBlur={() => handleInlineDescChange(todo.id, inlineEditValue)}
                                        onKeyDown={(e) => {
                                            if (e.key === 'Escape') {
                                                setInlineDescEditId(null);
                                                setInlineEditValue('');
                                            }
                                        }}
                                        className="w-full text-sm text-muted bg-surface border border-[--color-accent] rounded px-2 py-1 mt-1 focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] resize-none"
                                        rows={2}
                                        autoFocus
                                        placeholder="Add a description..."
                                    />
                                ) : (
                                    <p
                                        onClick={() => {
                                            setInlineDescEditId(todo.id);
                                            setInlineTitleEditId(null);
                                            setInlineEditValue(todo.description || '');
                                        }}
                                        className={`text-sm mt-1 font-light cursor-pointer hover:bg-paper-2 rounded px-1 -mx-1 ${todo.completed ? 'text-muted-soft' : 'text-muted'}`}
                                        title="Click to edit description"
                                    >
                                        {todo.description}
                                    </p>
                                )
                            )}

                            {/* Date */}
                            <div className="relative text-xs mt-1">
                                <DateTimePicker
                                    value={todo.due_date}
                                    onChange={(newDate) => handleInlineDateChange(todo.id, newDate)}
                                    placeholder="No Due Date"
                                    inline={true}
                                    dateColorClass={
                                        dateInfo?.isOverdue && !todo.completed
                                            ? 'text-danger font-medium'
                                            : dateInfo?.isToday
                                                ? 'text-warning font-medium'
                                                : dateInfo
                                                    ? 'text-ink-soft'
                                                    : 'text-muted-soft'
                                    }
                                />
                            </div>
                        </div>
                        <div className="flex gap-1">
                            <button
                                data-edit-button
                                onClick={(e) => {
                                    e.stopPropagation();
                                    // Use the button element directly, not event.currentTarget which may be affected by event delegation
                                    const buttonEl = e.currentTarget;
                                    handleEdit(todo, buttonEl);
                                }}
                                className="text-muted-soft hover:text-[--color-accent] transition-colors p-1 cursor-pointer"
                                title="Edit"
                            >
                                <Edit2 size={16} />
                            </button>
                            <button
                                onClick={() => handleDelete(todo.id)}
                                className="text-muted-soft hover:text-danger transition-colors p-1 cursor-pointer"
                                title="Delete"
                            >
                                <Trash2 size={16} />
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        );
    };

    const renderTagDropdown = () => {
        const dropdownContent = showTagDropdown && createPortal(
            <div
                ref={tagDropdownRef}
                className="fixed z-[9999] bg-surface border border-border rounded-lg shadow-lg max-h-60 overflow-auto"
                style={{
                    top: tagDropdownPosition.top + 4,
                    left: tagDropdownPosition.left,
                    width: Math.max(tagDropdownPosition.width, 160)
                }}
            >
                <div className="p-1">
                    {/* None option */}
                    <button
                        type="button"
                        onClick={() => handleTagSelect('')}
                        className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors text-muted"
                    >
                        None
                    </button>

                    {/* Predefined tags */}
                    {predefinedTags.map((tag) => (
                        <button
                            key={tag}
                            type="button"
                            onClick={() => handleTagSelect(tag)}
                            className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors flex items-center gap-2"
                        >
                            <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border ${getTagColor(tag)}`}>
                                <TagIcon size={10} />
                                {tag}
                            </span>
                        </button>
                    ))}

                    {/* Divider */}
                    <div className="border-t border-border my-1"></div>

                    {/* Add custom tag */}
                    {!isAddingCustomTag ? (
                        <button
                            type="button"
                            onClick={() => setIsAddingCustomTag(true)}
                            className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors text-[--color-accent] font-medium whitespace-nowrap"
                        >
                            + Add custom tag
                        </button>
                    ) : (
                        <div className="p-2 space-y-2" data-custom-tag-input>
                            <input
                                type="text"
                                value={customTagInput}
                                onChange={(e) => setCustomTagInput(e.target.value)}
                                onKeyDown={(e) => {
                                    if (e.key === 'Enter') {
                                        e.preventDefault();
                                        e.stopPropagation();
                                        handleAddCustomTag();
                                    } else if (e.key === 'Escape') {
                                        setIsAddingCustomTag(false);
                                        setCustomTagInput('');
                                    }
                                }}
                                placeholder="Enter tag name"
                                className="w-full px-2 py-1 text-sm border border-border-strong rounded focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring]"
                                autoFocus
                            />
                            <div className="flex gap-1">
                                <button
                                    type="button"
                                    onClick={handleAddCustomTag}
                                    className="flex-1 px-2 py-1 text-xs bg-[--color-accent] text-white rounded hover:bg-[--color-accent] transition-colors"
                                >
                                    Add
                                </button>
                                <button
                                    type="button"
                                    onClick={() => {
                                        setIsAddingCustomTag(false);
                                        setCustomTagInput('');
                                    }}
                                    className="flex-1 px-2 py-1 text-xs bg-border text-ink-soft rounded hover:bg-border-strong transition-colors"
                                >
                                    Cancel
                                </button>
                            </div>
                        </div>
                    )}
                </div>
            </div>,
            document.body
        );

        return (
            <div className="relative">
                <button
                    ref={tagButtonRef}
                    type="button"
                    onClick={handleTagButtonClick}
                    className="w-full px-3 py-2 border border-border rounded-lg focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] focus:border-transparent text-sm text-left flex items-center justify-between bg-surface hover:bg-paper-2 transition-colors"
                >
                    <span className={`whitespace-nowrap truncate ${formData.tag ? 'text-ink' : 'text-muted-soft'}`}>
                        {formData.tag || 'Select tag'}
                    </span>
                    <ChevronDown size={16} className="text-muted-soft flex-shrink-0 ml-2" />
                </button>
                {dropdownContent}
            </div>
        );
    };

    const handleEditTagSelect = (tag) => {
        setEditFormData({ ...editFormData, tag });
        setShowEditTagDropdown(false);
        setIsAddingCustomTag(false);
        setCustomTagInput('');
    };

    const handleAddEditCustomTag = () => {
        if (customTagInput.trim()) {
            setEditFormData({ ...editFormData, tag: customTagInput.trim() });
            setShowEditTagDropdown(false);
            setIsAddingCustomTag(false);
            setCustomTagInput('');
        }
    };

    const renderEditTagDropdown = () => {
        return (
            <div className="relative" ref={editTagDropdownRef}>
                <button
                    type="button"
                    onClick={(e) => {
                        const rect = e.currentTarget.getBoundingClientRect();
                        const dropdownHeight = 240; // max-h-60 = 240px
                        const viewportHeight = window.innerHeight;
                        const spaceBelow = viewportHeight - rect.bottom;
                        const spaceAbove = rect.top;

                        // Position above if not enough space below, and more space above
                        const positionAbove = spaceBelow < dropdownHeight && spaceAbove > spaceBelow;

                        setEditTagDropdownPosition({
                            top: positionAbove ? rect.top - dropdownHeight - 4 : rect.bottom + 4,
                            left: rect.left,
                            width: rect.width,
                        });
                        setShowEditTagDropdown(!showEditTagDropdown);
                    }}
                    className="w-full px-3 py-2 border border-border rounded-lg focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] focus:border-transparent text-sm text-left flex items-center justify-between bg-surface hover:bg-paper-2 transition-colors"
                >
                    <span className={`whitespace-nowrap truncate ${editFormData.tag ? 'text-ink' : 'text-muted-soft'}`}>
                        {editFormData.tag || 'Select tag'}
                    </span>
                    <ChevronDown size={16} className="text-muted-soft flex-shrink-0 ml-2" />
                </button>

                {showEditTagDropdown && (
                    <div
                        className="fixed z-[200] bg-surface border border-border rounded-lg shadow-lg max-h-60 overflow-auto"
                        style={{
                            top: `${editTagDropdownPosition.top}px`,
                            left: `${editTagDropdownPosition.left}px`,
                            minWidth: '160px',
                        }}
                    >
                        <div className="p-1">
                            {/* None option */}
                            <button
                                type="button"
                                onClick={() => handleEditTagSelect('')}
                                className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors text-muted"
                            >
                                None
                            </button>

                            {/* Predefined tags */}
                            {predefinedTags.map((tag) => (
                                <button
                                    key={tag}
                                    type="button"
                                    onClick={() => handleEditTagSelect(tag)}
                                    className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors flex items-center gap-2"
                                >
                                    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border ${getTagColor(tag)}`}>
                                        <TagIcon size={10} />
                                        {tag}
                                    </span>
                                </button>
                            ))}

                            {/* Divider */}
                            <div className="border-t border-border my-1"></div>

                            {/* Add custom tag */}
                            {!isAddingCustomTag ? (
                                <button
                                    type="button"
                                    onClick={() => setIsAddingCustomTag(true)}
                                    className="w-full text-left px-3 py-2 text-sm rounded hover:bg-paper-2 transition-colors text-[--color-accent] font-medium whitespace-nowrap"
                                >
                                    + Add custom tag
                                </button>
                            ) : (
                                <div className="p-2 space-y-2" data-custom-tag-input>
                                    <input
                                        type="text"
                                        value={customTagInput}
                                        onChange={(e) => setCustomTagInput(e.target.value)}
                                        onKeyDown={(e) => {
                                            if (e.key === 'Enter') {
                                                e.preventDefault();
                                                e.stopPropagation();
                                                handleAddEditCustomTag();
                                            } else if (e.key === 'Escape') {
                                                setIsAddingCustomTag(false);
                                                setCustomTagInput('');
                                            }
                                        }}
                                        placeholder="Enter tag name"
                                        className="w-full px-2 py-1 text-sm border border-border-strong rounded focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring]"
                                        autoFocus
                                    />
                                    <div className="flex gap-1">
                                        <button
                                            type="button"
                                            onClick={handleAddEditCustomTag}
                                            className="flex-1 px-2 py-1 text-xs bg-[--color-accent] text-white rounded hover:bg-[--color-accent] transition-colors"
                                        >
                                            Add
                                        </button>
                                        <button
                                            type="button"
                                            onClick={() => {
                                                setIsAddingCustomTag(false);
                                                setCustomTagInput('');
                                            }}
                                            className="flex-1 px-2 py-1 text-xs bg-border text-ink-soft rounded hover:bg-border-strong transition-colors"
                                        >
                                            Cancel
                                        </button>
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>
                )}
            </div>
        );
    };

    const renderAddForm = () => (
        <form
            onSubmit={handleAdd}
            className="space-y-3 mb-4"
            onKeyDown={(e) => {
                if (e.key === 'Escape' && isAddFormExpanded) {
                    e.preventDefault();
                    setIsAddFormExpanded(false);
                    resetForm();
                }
            }}
        >
            <div className="flex gap-2">
                <div className="flex-1">
                    <Input
                        ref={addInputRef}
                        value={formData.title}
                        onChange={(e) => {
                            setFormData({ ...formData, title: e.target.value });
                            if (titleError) setTitleError('');
                        }}
                        onFocus={() => setIsAddFormExpanded(true)}
                        placeholder="Add a new task..."
                        className={`w-full ${titleError ? 'border-danger focus:border-danger focus:ring-[--color-danger-soft]/20' : ''}`}
                    />
                    {titleError && (
                        <p className="text-danger text-xs mt-1">{titleError}</p>
                    )}
                </div>
                <Button
                    type="submit"
                    variant="primary"
                    className="!px-3"
                    disabled={!formData.title.trim()}
                    title={formData.title.trim() ? 'Add task' : 'Type a task first'}
                >
                    <Plus size={20} />
                </Button>
            </div>

            {isAddFormExpanded && (
                <div className="bg-paper-2/80 border border-divider rounded-lg p-4 space-y-3">
                    <textarea
                        value={formData.description}
                        onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                        placeholder="Description (optional)"
                        className="w-full px-4 py-2 border border-border rounded-lg focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] focus:border-transparent resize-none bg-surface"
                        rows="3"
                    />

                    <div className="grid grid-cols-2 gap-3">
                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Due Date</label>
                            <DateTimePicker
                                value={formData.due_date}
                                onChange={(newDate) => setFormData({ ...formData, due_date: newDate })}
                                placeholder="Select Date"
                            />
                        </div>

                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Tag</label>
                            {renderTagDropdown()}
                        </div>
                    </div>

                    <div className="flex items-center gap-2 pt-1">
                        <button
                            type="button"
                            onClick={() => {
                                setIsAddFormExpanded(false);
                                resetForm();
                            }}
                            className="flex-1 text-sm py-2 border border-border-strong rounded-lg hover:bg-paper-2 transition-colors text-ink-soft"
                        >
                            Cancel
                        </button>
                    </div>
                </div>
            )}
        </form>
    );

    const renderEditPopover = () => {
        if (!editingId) return null;

        // Use createPortal to render at document.body level, avoiding any transform/overflow issues
        return createPortal(
            <>
                {/* Backdrop */}
                <div className="fixed inset-0 z-40" aria-hidden="true" />

                {/* Popover */}
                <div
                    ref={popoverRef}
                    className="fixed z-50 w-96 bg-surface rounded-xl shadow-2xl border border-border p-4 max-h-[90vh] overflow-y-auto"
                    style={{
                        top: `${popoverPosition.top}px`,
                        left: `${popoverPosition.left}px`,
                    }}
                >
                    <div className="flex items-center justify-between mb-3">
                        <h3 className="font-semibold text-ink">Edit Task</h3>
                        <button
                            onClick={resetEditForm}
                            className="text-muted-soft hover:text-ink-soft transition-colors"
                        >
                            <X size={18} />
                        </button>
                    </div>

                    {editingTodo?.created_at && (
                        <div className="mb-3 pb-3 border-b border-border">
                            <div className="text-xs text-muted">
                                Created: {new Date(editingTodo.created_at).toLocaleString('en-US', {
                                    month: 'short',
                                    day: 'numeric',
                                    year: 'numeric',
                                    hour: 'numeric',
                                    minute: '2-digit',
                                    hour12: true
                                })}
                            </div>
                        </div>
                    )}

                    <form onSubmit={handleUpdate} className="space-y-3">
                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Title *</label>
                            <Input
                                value={editFormData.title}
                                onChange={(e) => setEditFormData({ ...editFormData, title: e.target.value })}
                                placeholder="Task title"
                                className="w-full"
                                required
                            />
                        </div>

                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Description</label>
                            <textarea
                                value={editFormData.description}
                                onChange={(e) => setEditFormData({ ...editFormData, description: e.target.value })}
                                placeholder="Add details..."
                                className="w-full px-3 py-2 border border-border rounded-lg focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] focus:border-transparent resize-none text-sm"
                                rows="3"
                            />
                        </div>

                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Due Date</label>
                            <DateTimePicker
                                value={editFormData.due_date}
                                onChange={(newDate) => setEditFormData({ ...editFormData, due_date: newDate })}
                                placeholder="Select Date"
                            />
                        </div>

                        <div>
                            <label className="block text-xs text-ink-soft mb-1">Tag</label>
                            {renderEditTagDropdown()}
                        </div>

                        <div className="flex gap-2 pt-2">
                            <Button type="submit" variant="primary" className="flex-1">
                                Update
                            </Button>
                            <Button type="button" onClick={resetEditForm} className="px-4">
                                Cancel
                            </Button>
                        </div>
                    </form>
                </div>
            </>,
            document.body
        );
    };

    return (
        <div tabIndex={-1} className="outline-none h-full flex flex-col">
            {renderEditPopover()}

            <Card
                title="Tasks"
                hideTitle={fullHeight}
                className={`flex flex-col ${fullHeight ? 'h-full' : 'max-h-[515px]'}`}
            >
                {renderAddForm()}

                {/* Filter bar and completed toggle */}
                {todos.length > 0 && (
                    <div className="flex items-center justify-between mb-3 px-1">
                        {/* Tag filter */}
                        <div className="relative" ref={filterDropdownRef}>
                            <button
                                onClick={() => setShowFilterDropdown(!showFilterDropdown)}
                                className={`inline-flex items-center gap-1.5 px-2.5 py-1.5 text-xs rounded-lg border transition-colors ${
                                    filterTag
                                        ? 'bg-[--color-accent-soft] border-[--color-accent] text-[--color-accent]'
                                        : 'bg-surface border-border text-ink-soft hover:bg-paper-2'
                                }`}
                            >
                                <Filter size={12} />
                                {filterTag || 'All tags'}
                                <ChevronDown size={12} />
                            </button>

                            {showFilterDropdown && (
                                <div className="absolute top-full left-0 mt-1 z-50 bg-surface border border-border rounded-lg shadow-lg min-w-32">
                                    <div className="p-1">
                                        <button
                                            onClick={() => {
                                                setFilterTag('');
                                                setShowFilterDropdown(false);
                                            }}
                                            className={`w-full text-left px-3 py-1.5 text-xs rounded hover:bg-paper-2 transition-colors ${!filterTag ? 'bg-paper-2 font-medium' : ''}`}
                                        >
                                            All tags
                                        </button>
                                        {predefinedTags.map((tag) => (
                                            <button
                                                key={tag}
                                                onClick={() => {
                                                    setFilterTag(tag);
                                                    setShowFilterDropdown(false);
                                                }}
                                                className={`w-full text-left px-3 py-1.5 text-xs rounded hover:bg-paper-2 transition-colors flex items-center gap-2 ${filterTag === tag ? 'bg-paper-2 font-medium' : ''}`}
                                            >
                                                <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border ${getTagColor(tag)}`}>
                                                    <TagIcon size={10} />
                                                    {tag}
                                                </span>
                                            </button>
                                        ))}
                                    </div>
                                </div>
                            )}
                        </div>

                    </div>
                )}

                <div className="flex-1 overflow-y-auto custom-scrollbar space-y-2 pr-1">
                    {loading ? (
                        <div className="flex justify-center items-center h-20 text-[--color-accent]">
                            <Loader2 className="animate-spin" />
                        </div>
                    ) : todos.length === 0 ? (
                        <div className="text-center text-muted-soft mt-10">No tasks yet.</div>
                    ) : (() => {
                        // Filter active todos (non-completed) based on tag filter
                        const activeTodos = todos.filter(todo => {
                            if (filterTag && todo.tag !== filterTag) return false;
                            return !todo.completed;
                        });

                        // Filter completed todos based on tag filter
                        const completedTodos = todos.filter(todo => {
                            if (filterTag && todo.tag !== filterTag) return false;
                            return todo.completed;
                        });

                        const categorized = categorizeTodos(activeTodos);
                        const hasOverdue = categorized.overdue.length > 0;
                        const hasToday = categorized.today.length > 0;
                        const hasThisWeek = categorized['this-week'].length > 0;
                        const hasRemaining = categorized.remaining.length > 0;
                        const hasNoDate = categorized['no-date'].length > 0;
                        const hasActiveTodos = activeTodos.length > 0;

                        // Categorize completed todos by date (using different buckets)
                        const completedCategorized = categorizeCompletedTodos(completedTodos);

                        return (
                            <div className="space-y-4">
                                {!hasActiveTodos && completedTodos.length === 0 && (
                                    <div className="text-center text-muted-soft mt-10">
                                        {filterTag ? `No tasks with tag "${filterTag}"` : 'No active tasks'}
                                    </div>
                                )}

                                {/* Overdue Section */}
                                {hasOverdue && (
                                    <div>
                                        <div className="flex items-center gap-2 mb-2 px-2">
                                            <h3 className="text-sm font-semibold text-danger">
                                                Overdue
                                            </h3>
                                            <span className="text-xs text-danger bg-danger-soft px-2 py-0.5 rounded-full">
                                                {categorized.overdue.length}
                                            </span>
                                        </div>
                                        <div className="space-y-2">
                                            {categorized.overdue.map(renderTodoItem)}
                                        </div>
                                    </div>
                                )}

                                {/* Today Section */}
                                {hasToday && (
                                    <div>
                                        <div className="flex items-center gap-2 mb-2 px-2">
                                            <h3 className="text-sm font-semibold text-warning">
                                                Today
                                            </h3>
                                            <span className="text-xs text-warning bg-warning-soft px-2 py-0.5 rounded-full">
                                                {categorized.today.length}
                                            </span>
                                        </div>
                                        <div className="space-y-2">
                                            {categorized.today.map(renderTodoItem)}
                                        </div>
                                    </div>
                                )}

                                {/* This Week Section */}
                                {hasThisWeek && (
                                    <div>
                                        <div className="flex items-center gap-2 mb-2 px-2">
                                            <h3 className="text-sm font-semibold text-ink-soft">
                                                This Week
                                            </h3>
                                            <span className="text-xs text-ink-soft bg-paper-2 px-2 py-0.5 rounded-full">
                                                {categorized['this-week'].length}
                                            </span>
                                        </div>
                                        <div className="space-y-2">
                                            {categorized['this-week'].map(renderTodoItem)}
                                        </div>
                                    </div>
                                )}

                                {/* Remaining Section */}
                                {hasRemaining && (
                                    <div>
                                        <div className="flex items-center gap-2 mb-2 px-2">
                                            <h3 className="text-sm font-semibold text-ink-soft">
                                                Remaining
                                            </h3>
                                            <span className="text-xs text-ink-soft bg-paper-2 px-2 py-0.5 rounded-full">
                                                {categorized.remaining.length}
                                            </span>
                                        </div>
                                        <div className="space-y-2">
                                            {categorized.remaining.map(renderTodoItem)}
                                        </div>
                                    </div>
                                )}

                                {/* No Date Section */}
                                {hasNoDate && (
                                    <div>
                                        <div className="flex items-center gap-2 mb-2 px-2">
                                            <h3 className="text-sm font-semibold text-muted">
                                                No Due Date
                                            </h3>
                                            <span className="text-xs text-muted bg-paper-2 px-2 py-0.5 rounded-full">
                                                {categorized['no-date'].length}
                                            </span>
                                        </div>
                                        <div className="space-y-2">
                                            {categorized['no-date'].map(renderTodoItem)}
                                        </div>
                                    </div>
                                )}

                                {/* Completed Section */}
                                {completedTodos.length > 0 && (
                                    <div className="border-t border-border pt-4 mt-4">
                                        <button
                                            onClick={() => setShowCompleted(!showCompleted)}
                                            className="flex items-center gap-2 mb-2 px-2 w-full text-left hover:bg-paper-2 rounded-lg py-1 transition-colors"
                                        >
                                            <ChevronRight size={16} className={`text-success transition-transform ${showCompleted ? 'rotate-90' : ''}`} />
                                            <h3 className="text-sm font-semibold text-success">
                                                Completed
                                            </h3>
                                            <span className="text-xs text-success bg-success-soft px-2 py-0.5 rounded-full">
                                                {completedTodos.length}
                                            </span>
                                        </button>

                                        {showCompleted && (
                                            <div className="space-y-4 mt-2 pl-2">
                                                {/* Completed - Today */}
                                                {completedCategorized.today.length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Today</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized.today.length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized.today.map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Tomorrow */}
                                                {completedCategorized.tomorrow.length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Tomorrow</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized.tomorrow.length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized.tomorrow.map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - This Week */}
                                                {completedCategorized['this-week'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">This Week</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['this-week'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['this-week'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - This Month */}
                                                {completedCategorized['this-month'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">This Month</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['this-month'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['this-month'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - This Year (Future) */}
                                                {completedCategorized['this-year-future'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">This Year</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['this-year-future'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['this-year-future'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Next Year */}
                                                {completedCategorized['next-year'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Next Year</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['next-year'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['next-year'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Future */}
                                                {completedCategorized.future.length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Future</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized.future.length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized.future.map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Yesterday */}
                                                {completedCategorized.yesterday.length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Yesterday</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized.yesterday.length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized.yesterday.map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Last 7 Days */}
                                                {completedCategorized['last-7-days'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Last 7 Days</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['last-7-days'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['last-7-days'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Last 30 Days */}
                                                {completedCategorized['last-30-days'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Last 30 Days</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['last-30-days'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['last-30-days'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Earlier This Year */}
                                                {completedCategorized['this-year-past'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Earlier This Year</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['this-year-past'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['this-year-past'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Last Year */}
                                                {completedCategorized['last-year'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Last Year</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['last-year'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['last-year'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - Past */}
                                                {completedCategorized.past.length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">Past</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized.past.length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized.past.map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}

                                                {/* Completed - No Date */}
                                                {completedCategorized['no-date'].length > 0 && (
                                                    <div>
                                                        <div className="flex items-center gap-2 mb-2 px-2">
                                                            <h4 className="text-xs font-medium text-muted">No Due Date</h4>
                                                            <span className="text-xs text-muted-soft bg-paper-2 px-1.5 py-0.5 rounded-full">
                                                                {completedCategorized['no-date'].length}
                                                            </span>
                                                        </div>
                                                        <div className="space-y-2">
                                                            {completedCategorized['no-date'].map(renderTodoItem)}
                                                        </div>
                                                    </div>
                                                )}
                                            </div>
                                        )}
                                    </div>
                                )}
                            </div>
                        );
                    })()}
                </div>
            </Card>

            {/* Tooltip Portal */}
            {tooltipData.visible && createPortal(
                <div
                    className="fixed z-[9999] bg-ink text-white text-xs rounded py-1 px-2 shadow-lg pointer-events-none whitespace-normal"
                    style={{
                        left: tooltipData.x,
                        top: tooltipData.y,
                        maxWidth: '300px'
                    }}
                >
                    {tooltipData.text}
                </div>,
                document.body
            )}
        </div>
    );
});

export default TodoWidget;
