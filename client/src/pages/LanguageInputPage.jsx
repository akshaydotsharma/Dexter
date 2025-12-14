import { useState, useEffect, useRef } from 'react';
import { aiParse } from '../services/api';

function LanguageInputPage() {
    const [input, setInput] = useState('');
    const [isProcessing, setIsProcessing] = useState(false);
    const [isListening, setIsListening] = useState(false);
    const [logs, setLogs] = useState([]);
    const [bottomOffset, setBottomOffset] = useState(0);
    const [isMobile, setIsMobile] = useState(false);

    const recognitionRef = useRef(null);
    const scrollRef = useRef(null);
    const containerRef = useRef(null);
    const inputRef = useRef(null);

    // Detect mobile viewport and browser bottom UI (nav bar)
    useEffect(() => {
        const checkMobile = () => setIsMobile(window.innerWidth < 768);
        checkMobile();

        const updateBottomOffset = () => {
            if (window.visualViewport) {
                // Calculate the difference between window height and visual viewport height
                const offset = window.innerHeight - window.visualViewport.height - window.visualViewport.offsetTop;
                setBottomOffset(Math.max(0, offset));
            }
        };

        updateBottomOffset();

        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', updateBottomOffset);
            window.visualViewport.addEventListener('scroll', updateBottomOffset);
        }
        window.addEventListener('resize', updateBottomOffset);
        window.addEventListener('resize', checkMobile);

        return () => {
            if (window.visualViewport) {
                window.visualViewport.removeEventListener('resize', updateBottomOffset);
                window.visualViewport.removeEventListener('scroll', updateBottomOffset);
            }
            window.removeEventListener('resize', updateBottomOffset);
            window.removeEventListener('resize', checkMobile);
        };
    }, []);

    // Auto-scroll to bottom of logs
    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [logs]);

    // Auto-focus input on page load
    useEffect(() => {
        if (inputRef.current) {
            inputRef.current.focus();
        }
    }, []);

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
        setInput(''); // Clear immediately for better UX
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

    const hasStarted = logs.length > 0;

    return (
        <div className="flex flex-col h-full bg-slate-50 relative overflow-hidden transition-all duration-500">
            {/* Content Container */}
            {/* Mobile: input always at bottom (justify-between), Desktop: centered when not started */}
            <div className={`flex flex-col w-full h-full transition-all duration-500 justify-between ${!hasStarted ? 'md:justify-center md:items-center' : ''}`}>

                {/* Hero Text (Only visible when no chat logs) */}
                {!hasStarted && (
                    <div className="flex-1 md:flex-initial flex items-center justify-center">
                        <div className="text-center space-y-6 animate-in fade-in zoom-in duration-500 flex flex-col items-center px-8 md:px-4 md:mb-10">
                            <div className="relative group p-4">
                                <div className="absolute inset-0 bg-indigo-100 rounded-full blur-xl opacity-50 group-hover:opacity-100 animate-pulse transition-opacity" />
                                <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="text-indigo-500 relative z-10 animate-bounce" style={{ animationDuration: '3s' }}>
                                    <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                                    <path d="M8 10h.01" />
                                    <path d="M12 10h.01" />
                                    <path d="M16 10h.01" />
                                </svg>
                            </div>

                            <div className="space-y-2">
                                <h1 className="text-3xl font-semibold text-slate-700 tracking-tight">
                                    What can I help you organize?
                                </h1>
                                <p className="hidden md:block text-base text-slate-400 max-w-lg mx-auto font-medium">
                                    Try saying "Remind me to call John tomorrow" or "Create a grocery list with milk and eggs".
                                </p>
                            </div>
                        </div>
                    </div>
                )}

                {/* Chat History (Only visible when started) */}
                {hasStarted && (
                    <div
                        ref={scrollRef}
                        className="flex-1 overflow-y-auto p-4 md:p-8 z-10 space-y-6 scroll-smooth w-full max-w-4xl mx-auto"
                    >
                        {logs.map((msg, idx) => (
                            <div
                                key={idx}
                                className={`flex w-full ${msg.role === 'user' ? 'justify-end' : 'justify-start'} animate-in fade-in slide-in-from-bottom-4 duration-300`}
                            >
                                <div className={`
                                    max-w-[85%] md:max-w-[70%] p-4 rounded-2xl shadow-sm text-base leading-relaxed
                                    ${msg.role === 'user'
                                        ? 'bg-indigo-600 text-white rounded-br-none'
                                        : 'bg-white text-slate-700 border border-slate-100 rounded-bl-none'}
                                `}>
                                    {msg.content}
                                </div>
                            </div>
                        ))}
                        {isProcessing && (
                            <div className="flex w-full justify-start animate-in fade-in">
                                <div className="bg-white p-4 rounded-2xl rounded-bl-none border border-slate-100 shadow-sm flex items-center gap-2">
                                    <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '0ms' }} />
                                    <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '150ms' }} />
                                    <div className="w-2 h-2 rounded-full bg-indigo-400 animate-bounce" style={{ animationDelay: '300ms' }} />
                                </div>
                            </div>
                        )}
                    </div>
                )}

                {/* Input Area - with dynamic padding for mobile browser nav bars */}
                {/* Mobile: 8rem (128px) base padding for browser nav bar + dynamic offset */}
                {/* Desktop: just 1rem base + dynamic offset */}
                <div
                    className="z-20 p-4 w-full transition-all duration-500"
                    style={{ paddingBottom: isMobile ? `calc(8rem + ${bottomOffset}px)` : `calc(1rem + ${bottomOffset}px)` }}
                >
                    {/* Helper text - above input on mobile */}
                    {!hasStarted && (
                        <p className="md:hidden text-xs text-slate-400 text-center mb-3 px-4">
                            Try "Remind me to call Mom tomorrow" or "Create a shopping list with milk and eggs"
                        </p>
                    )}
                    <div className="max-w-3xl mx-auto relative group">
                        {/* The Shiny Gradient Border - hidden on mobile */}
                        <div className="hidden md:block absolute -inset-[3px] rounded-2xl bg-linear-to-r from-indigo-500 via-purple-500 to-pink-500 opacity-70 blur-sm group-hover:opacity-100 transition duration-500 animate-border-spin" />

                        {/* The Actual Input Container */}
                        <div className="relative bg-white rounded-full md:rounded-xl flex items-center p-2 border border-slate-200 md:border-0 md:shadow-xl">
                            <textarea
                                ref={inputRef}
                                value={input}
                                onChange={(e) => setInput(e.target.value)}
                                onKeyDown={handleKeyDown}
                                placeholder="Add a new Task, Note or to do"
                                className="flex-1 max-h-32 min-h-[40px] md:min-h-[56px] py-1 md:py-3 px-4 md:px-4 bg-transparent outline-none text-slate-800 placeholder:text-slate-400 resize-none font-medium text-base md:text-base leading-[38px] md:leading-normal"
                                rows={1}
                            />

                            {/* Actions */}
                            <div className="flex items-center gap-1 md:gap-2 pr-1 md:pr-2">
                                <button
                                    onClick={toggleListening}
                                    className={`p-2 rounded-full transition-colors ${isListening
                                        ? 'bg-red-50 text-red-500 animate-pulse'
                                        : 'hover:bg-slate-100 text-slate-400 hover:text-indigo-600'
                                        }`}
                                    title="Voice Input"
                                >
                                    <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z" />
                                    </svg>
                                </button>

                                <button
                                    onClick={handleProcess}
                                    disabled={!input.trim() || isProcessing}
                                    className={`p-2 rounded-xl transition-all ${!input.trim() || isProcessing
                                        ? 'bg-slate-100 text-slate-300 cursor-not-allowed'
                                        : 'bg-indigo-600 text-white shadow-lg shadow-indigo-200 hover:bg-indigo-700 active:scale-95'
                                        }`}
                                    title="Send"
                                >
                                    <svg xmlns="http://www.w3.org/2000/svg" className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                                        <path d="M10.894 2.553a1 1 0 00-1.788 0l-7 14a1 1 0 001.169 1.409l5-1.429A1 1 0 009 15.571V11a1 1 0 112 0v4.571a1 1 0 00.725.962l5 1.428a1 1 0 001.17-1.408l-7-14z" />
                                    </svg>
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}

export default LanguageInputPage;
