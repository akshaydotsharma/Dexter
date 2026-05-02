/**
 * Preferences helpers extracted so tests can exercise the merge/hydrate logic
 * without standing up the whole Express app. The HTTP route in index.js
 * imports the same functions so behaviour can't drift.
 */

const { z } = require('zod');

const DEFAULT_PREFERENCES = {
    theme: 'system',
    default_view: 'today',
    density: 'comfortable',
    sidebar_collapsed_default: true,
    wordmark: 'Dashy',
    ai: {
        stream: true,
        model: 'gpt-4o',
    },
    dashboard_widget_order: ['todos', 'notes', 'lists'],
};

const DEFAULT_WIDGETS = ['todos', 'notes', 'lists'];

const preferencesPatchSchema = z.object({
    theme: z.enum(['light', 'dark', 'system']).optional(),
    default_view: z.enum(['today', 'chat', 'dashboard', 'tasks', 'notes', 'lists']).optional(),
    density: z.enum(['comfortable', 'compact']).optional(),
    sidebar_collapsed_default: z.boolean().optional(),
    wordmark: z.string().min(1).max(50).optional(),
    ai: z.object({
        stream: z.boolean().optional(),
        model: z.string().min(1).max(100).optional(),
    }).strict().optional(),
    dashboard_widget_order: z.array(z.string().min(1)).optional(),
}).strict();

/**
 * Deep-merge plain objects. Arrays and primitives replace. Returns a new
 * object — does not mutate inputs.
 */
function deepMerge(base, patch) {
    if (patch == null) return base;
    if (typeof patch !== 'object' || Array.isArray(patch)) return patch;
    const out = { ...(base || {}) };
    for (const [k, v] of Object.entries(patch)) {
        if (v && typeof v === 'object' && !Array.isArray(v)
            && out[k] && typeof out[k] === 'object' && !Array.isArray(out[k])) {
            out[k] = deepMerge(out[k], v);
        } else {
            out[k] = v;
        }
    }
    return out;
}

/**
 * Fill defaults into a stored layout_preference value. Always returns the
 * full shape so the client never has to fall back.
 */
function hydrateLayoutPreference(stored) {
    const base = stored && typeof stored === 'object' ? stored : {};
    return {
        widgets: Array.isArray(base.widgets) ? base.widgets : DEFAULT_WIDGETS.slice(),
        preferences: deepMerge(DEFAULT_PREFERENCES, base.preferences || {}),
    };
}

module.exports = {
    DEFAULT_PREFERENCES,
    DEFAULT_WIDGETS,
    preferencesPatchSchema,
    deepMerge,
    hydrateLayoutPreference,
};
