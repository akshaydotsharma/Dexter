import { useState, useEffect, useRef } from 'react';
import { aiParse } from '../services/api';
import { X } from 'lucide-react';

export default function ChatPopover({ isOpen, onClose }) {
    const [input, setInput] = useState('');
    const [isProcessing, setIsProcessing] = useState(false);
    const [isListening, setIsListening] = useState(false);
    const [logs, setLogs] = useState([]);

    const recognitionRef = useRef(null);
    const scrollRef = useRef(null);

    // Auto-scroll to bottom of logs
    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [logs]);

    useEffect(() => {
        if ('webkitSpeechRecognition' in window) {
            const recognition = new window.webkitSpeechRecognition();
            recognition.continuous = false;
            recognition.interimResults = false;
            recognition.lang = 'en-US';

            recognition.onstart = () => setIsListening(true);
            recognition.onend = () => setIsListening(false);
            recognition.onerror = (event) => {
                console.error("Speech recognition error", event.error);
                setIsListening(false);
                addLog('system', `Error: Speech recognition failed (${event.error})`);
            };
            recognition.onresult = (event) => {
                const transcript = event.results[0][0].transcript;
                setInput(prev => prev ? `${prev} ${transcript}` : transcript);
            };

            recognitionRef.current = recognition;
        }
    }, []);

    const addLog = (role, message) => {
        setLogs(prev => [...prev, { role, content: message }]);
    };

    const toggleListening = () => {
        if (!recognitionRef.current) {
            addLog('system', "Error: Speech recognition not supported in this browser.");
            return;
        }
        if (isListening) {
            recognitionRef.current.stop();
        } else {
            recognitionRef.current.start();
        }
    };

    const handleProcess = async () => {
        if (!input.trim()) return;

        const userText = input;
        setInput('');
        addLog('user', userText);
        setIsProcessing(true);

        try {
            const response = await aiParse(userText);
            const result = response.data;

            if (result.success) {
                // Build parsed details string
                const parsed = result.parsed;
                let details = '';
                if (parsed) {
                    const parts = [];
                    if (parsed.title) parts.push(`Title: ${parsed.title}`);
                    if (parsed.description) parts.push(`Description: ${parsed.description}`);
                    if (parsed.content) parts.push(`Content: ${parsed.content}`);
                    if (parsed.due_date) parts.push(`Due: ${new Date(parsed.due_date).toLocaleString()}`);
                    if (parsed.tag) parts.push(`Tag: ${parsed.tag}`);
                    if (parsed.items) parts.push(`Items: ${parsed.items.join(', ')}`);
                    if (parts.length > 0) {
                        details = `\n\nParsed: ${parts.join(' | ')}`;
                    }
                }
                addLog('system', `✅ ${result.message}${details}`);
            } else {
                addLog('system', `💬 ${result.message}`);
            }

        } catch (error) {
            console.error("Error processing input:", error);
            const errorMessage = error.response?.data?.error || error.message || "Failed to process request";
            addLog('system', `❌ Error: ${errorMessage}`);
        } finally {
            setIsProcessing(false);
        }
    };

    const handleKeyDown = (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            handleProcess();
        }
    };

    if (!isOpen) return null;

    return (
        <>
            {/* Backdrop */}
            <div
                className="fixed inset-0 bg-black/20 z-40 animate-in fade-in duration-200"
                onClick={onClose}
            />

            {/* Popover */}
            <div className="fixed bottom-8 right-8 w-[380px] h-[520px] bg-white rounded-2xl shadow-2xl z-50 flex flex-col animate-in slide-in-from-bottom-8 fade-in duration-300 overflow-hidden">
                {/* Header with Subtle Background */}
                <div className="flex items-center justify-between px-4 py-3 bg-slate-100 border-b border-slate-200">
                    <div className="flex items-center gap-2">
                        <div className="w-2 h-2 rounded-full bg-indigo-500 animate-pulse" />
                        <h2 className="text-sm font-semibold text-slate-700">AI Assistant</h2>
                    </div>
                    <button
                        onClick={onClose}
                        className="p-1 hover:bg-slate-200 rounded-lg transition-colors"
                    >
                        <X className="w-4 h-4 text-slate-500" />
                    </button>
                </div>

                {/* Chat Area */}
                <div
                    ref={scrollRef}
                    className="flex-1 overflow-y-auto p-4 space-y-4"
                >
                    {logs.length === 0 ? (
                        <div className="flex items-center justify-center h-full text-center text-slate-400 text-xs px-6">
                            <p>Start a conversation! Try "todo Buy milk" or "note Meeting notes"</p>
                        </div>
                    ) : (
                        <>
                            {logs.map((msg, idx) => (
                                <div
                                    key={idx}
                                    className={`flex w-full ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
                                >
                                    <div className={`
                                        max-w-[85%] p-3 rounded-xl text-sm leading-relaxed
                                        ${msg.role === 'user'
                                            ? 'bg-indigo-600 text-white rounded-br-none'
                                            : 'bg-slate-100 text-slate-700 rounded-bl-none'}
                                    `}>
                                        {msg.content}
                                    </div>
                                </div>
                            ))}
                            {isProcessing && (
                                <div className="flex w-full justify-start">
                                    <div className="bg-slate-100 p-3 rounded-xl rounded-bl-none flex items-center gap-2">
                                        <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '0ms' }} />
                                        <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '150ms' }} />
                                        <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '300ms' }} />
                                    </div>
                                </div>
                            )}
                        </>
                    )}
                </div>

                {/* Input Area */}
                <div className="p-4 border-t border-slate-200">
                    <div className="relative bg-white rounded-lg flex items-center p-2 border border-slate-200 hover:border-indigo-300 transition-colors">
                        <textarea
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={handleKeyDown}
                            placeholder="Add a new Task, Note or to do"
                            className="flex-1 max-h-24 min-h-[40px] py-2 px-3 bg-transparent outline-none text-slate-800 placeholder:text-slate-400 resize-none text-sm"
                            rows={1}
                        />

                        {/* Actions */}
                        <div className="flex items-center gap-1">
                            <button
                                onClick={toggleListening}
                                className={`p-2 rounded-lg transition-colors ${isListening
                                    ? 'bg-red-50 text-red-500 animate-pulse'
                                    : 'hover:bg-slate-100 text-slate-400 hover:text-indigo-600'
                                    }`}
                                title="Voice Input"
                            >
                                <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z" />
                                </svg>
                            </button>

                            <button
                                onClick={handleProcess}
                                disabled={!input.trim() || isProcessing}
                                className={`p-2 rounded-lg transition-all ${!input.trim() || isProcessing
                                    ? 'bg-slate-100 text-slate-300 cursor-not-allowed'
                                    : 'bg-indigo-600 text-white hover:bg-indigo-700 active:scale-95'
                                    }`}
                                title="Send"
                            >
                                <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                                    <path d="M10.894 2.553a1 1 0 00-1.788 0l-7 14a1 1 0 001.169 1.409l5-1.429A1 1 0 009 15.571V11a1 1 0 112 0v4.571a1 1 0 00.725.962l5 1.428a1 1 0 001.17-1.408l-7-14z" />
                                </svg>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </>
    );
}
