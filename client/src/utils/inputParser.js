/**
 * Parses natural language input into an actionable command.
 * Supported formats:
 * - "todo [text]"
 * - "note [title]: [content]"
 * - "list [title]: [item1], [item2], ..."
 * 
 * @param {string} input 
 * @returns {Object} { type: 'todo'|'note'|'list'|'unknown', payload: any, raw: string }
 */
export const parseInput = (input) => {
    const trimmed = input.trim();
    // Normalize: remove potential colon after keyword for easier parsing
    // "todo: something" -> "todo something"
    // "Note: title: content" -> "note title: content"

    // We want to match the first word
    const firstSpace = trimmed.indexOf(' ');
    let keyword = trimmed;
    let remainder = '';

    if (firstSpace !== -1) {
        keyword = trimmed.substring(0, firstSpace).toLowerCase();
        remainder = trimmed.substring(firstSpace + 1).trim();
    } else {
        keyword = trimmed.toLowerCase();
    }

    // specific handling for "todo", "todo:", "note", "note:", "list", "list:"
    const cleanKeyword = keyword.replace(':', '');

    if (cleanKeyword === 'todo') {
        const text = remainder;
        if (!text) return { type: 'unknown', raw: trimmed }; // "todo" empty
        return { type: 'todo', payload: { text }, raw: trimmed };
    }

    if (cleanKeyword === 'note') {
        const firstColon = remainder.indexOf(':');

        let title = remainder;
        let content = '';

        if (firstColon !== -1) {
            title = remainder.substring(0, firstColon).trim();
            content = remainder.substring(firstColon + 1).trim();
        } else {
            // If no colon in remainder, assume it's just content with a default title, 
            // OR title with empty content? 
            // Let's stick to previous logic: content = remainder, title = "Quick Note"
            content = remainder;
            title = "Quick Note";
        }

        if (!content && !title) return { type: 'unknown', raw: trimmed };

        return { type: 'note', payload: { title, content }, raw: trimmed };
    }

    if (cleanKeyword === 'list') {
        const firstColon = remainder.indexOf(':');

        let title = "New List";
        let itemsString = remainder;

        if (firstColon !== -1) {
            title = remainder.substring(0, firstColon).trim();
            itemsString = remainder.substring(firstColon + 1).trim();
        }

        if (!itemsString) return { type: 'unknown', raw: trimmed };

        const items = itemsString.split(',').map(i => i.trim()).filter(i => i.length > 0);
        return { type: 'list', payload: { title, items }, raw: trimmed };
    }

    return { type: 'unknown', raw: trimmed };
};
