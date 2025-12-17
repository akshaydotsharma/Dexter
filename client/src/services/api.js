import axios from 'axios';

const api = axios.create({
  baseURL: import.meta.env.VITE_API_URL || '/api',
  headers: {
    'Content-Type': 'application/json',
  },
});

export const getTodos = () => api.get('/todos');
export const createTodo = (todoData) => api.post('/todos', todoData);
export const updateTodo = (id, updates) => api.put(`/todos/${id}`, updates);
export const deleteTodo = (id, permanent = false) => api.delete(`/todos/${id}${permanent ? '?permanent=true' : ''}`);
export const restoreTodo = (id) => api.post(`/todos/${id}/restore`);
export const getTodoHistory = (id) => api.get(`/todos/${id}/history`);
export const getAllTodoHistory = (limit = 50) => api.get(`/todo-history?limit=${limit}`);

// Note Folders
export const getNoteFolders = () => api.get('/note-folders');
export const createNoteFolder = (name) => api.post('/note-folders', { name });
export const updateNoteFolder = (id, name) => api.put(`/note-folders/${id}`, { name });
export const deleteNoteFolder = (id) => api.delete(`/note-folders/${id}`);

// Notes
export const getNotes = (folderId) => api.get('/notes', { params: folderId ? { folder_id: folderId } : {} });
export const createNote = (title, content, folderId) => api.post('/notes', { title, content, folder_id: folderId });
export const updateNote = (id, title, content, folderId) => api.put(`/notes/${id}`, { title, content, folder_id: folderId });
export const deleteNote = (id) => api.delete(`/notes/${id}`);
export const getNoteHistory = (id) => api.get(`/notes/${id}/history`);
export const getAllNoteHistory = (limit = 50) => api.get(`/note-history?limit=${limit}`);

// Lists
export const getLists = () => api.get('/lists');
export const createList = (title, items) => api.post('/lists', { title, items });
export const updateList = (id, title, items) => api.put(`/lists/${id}`, { title, items });
export const deleteList = (id) => api.delete(`/lists/${id}`);
export const getListHistory = (id) => api.get(`/lists/${id}/history`);
export const getAllListHistory = (limit = 50) => api.get(`/list-history?limit=${limit}`);

export const getConfig = () => api.get('/config');
export const updateConfig = (layout_preference) => api.put('/config', { layout_preference });

export const getStats = () => api.get('/stats');

// AI Parse endpoint
export const aiParse = (input) => api.post('/ai/parse', { input });

// Draft Actions endpoints - v2.0
export const getDrafts = (status = 'pending') => api.get('/drafts', { params: { status } });
export const getDraft = (id) => api.get(`/drafts/${id}`);
export const confirmDraft = (id, updatedData) => api.post(`/drafts/${id}/confirm`, updatedData ? { updatedData } : {});
export const rejectDraft = (id) => api.post(`/drafts/${id}/reject`);
export const updateDraft = (id, draft_data) => api.put(`/drafts/${id}`, { draft_data });
export const bulkDraftAction = (action, draft_ids) => api.post('/drafts/bulk', { action, draft_ids });

// AI Execute endpoint - v2.0 (alternative to confirm, cleaner API)
export const executeDraft = (draft_id, updatedData) => api.post('/ai/execute', { draft_id, updatedData });

export default api;
