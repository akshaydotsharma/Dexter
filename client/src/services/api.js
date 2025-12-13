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
export const deleteTodo = (id) => api.delete(`/todos/${id}`);

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

export const getLists = () => api.get('/lists');
export const createList = (title, items) => api.post('/lists', { title, items });
export const updateList = (id, title, items) => api.put(`/lists/${id}`, { title, items });
export const deleteList = (id) => api.delete(`/lists/${id}`);

export const getConfig = () => api.get('/config');
export const updateConfig = (layout_preference) => api.put('/config', { layout_preference });

export const getStats = () => api.get('/stats');

// AI Parse endpoint
export const aiParse = (input) => api.post('/ai/parse', { input });

export default api;
