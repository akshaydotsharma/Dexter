import { useEffect, useRef, useState } from 'react';
import { Sparkles, Mic, Square, ArrowUp } from 'lucide-react';
import ChatSuccessRow from '../components/ChatSuccessRow';
import Chip from '../components/Chip';
import DraftPreviewCard from '../components/DraftPreviewCard';
import { useChatContext } from '../contexts/chat-context';
import useSpeechRecognition from '../hooks/useSpeechRecognition';

const EXAMPLE_PROMPTS = [
    'Remind me to call John tomorrow',
    'New shopping list with milk and eggs',
    'Note: ideas for Q3 OKRs',
];

/**
 * v2 Chat — full-page chat surface (replaces the legacy LanguageInputPage).
 *
 * Visuals follow refactor-v2 §7 (Chat bubbles + Input bar) and §12 prep
 * (the SSE wiring lands when /api/ai/parse/stream is exposed). The state
 * machine lives in `useChat` so this page and the floating ChatPopover
 * share the same flow.
 */
export default function ChatPage() {
    // ChatPage reads from a context that lives above the route boundary so
    // navigating away (via a SuccessRow link) and back keeps the conversation.
    const {
        logs,
        pendingDrafts,
        isProcessing,
        send,
        confirmDraft,
        rejectDraft,
        applyInlineEdit,
    } = useChatContext();
    const speech = useSpeechRecognition();

    const [input, setInput] = useState('');
    const [bottomOffset, setBottomOffset] = useState(0);
    const [isMobile, setIsMobile] = useState(false);

    const scrollRef = useRef(null);
    const inputRef = useRef(null);

    // Mobile + iOS safe-area handling — keep parity with the legacy page.
    useEffect(() => {
        const checkMobile = () => setIsMobile(window.innerWidth < 768);
        checkMobile();

        const updateBottomOffset = () => {
            if (window.visualViewport) {
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

    // Auto-scroll on new turn. Honour prefers-reduced-motion.
    useEffect(() => {
        const el = scrollRef.current;
        if (!el) return;
        const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
        el.scrollTo({
            top: el.scrollHeight,
            behavior: reduced ? 'auto' : 'smooth',
        });
    }, [logs, pendingDrafts.length, isProcessing]);

    // Wire voice transcript into the input box.
    useEffect(() => {
        speech.onTranscript((transcript) => {
            setInput((prev) => (prev ? `${prev} ${transcript}` : transcript));
        });
    }, [speech]);

    // Auto-focus input on mount.
    useEffect(() => {
        inputRef.current?.focus();
    }, []);

    const handleSend = async () => {
        const text = input.trim();
        if (!text) return;
        setInput('');
        await send(text);
    };

    const handleKeyDown = (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            handleSend();
        }
    };

    const hasStarted = logs.length > 0 || pendingDrafts.length > 0;

    return (
        <div className="flex flex-col h-full bg-paper relative overflow-hidden">
            <div className={`flex flex-col w-full h-full justify-between ${!hasStarted ? 'md:justify-center md:items-center' : ''}`}>

                {/* Empty state */}
                {!hasStarted && (
                    <div className="flex-1 md:flex-initial flex items-center justify-center">
                        <div className="px-8 md:px-4 md:mb-10 flex flex-col items-center text-center space-y-5 max-w-xl">
                            <Sparkles size={32} strokeWidth={1.75} className="text-muted" aria-hidden="true" />
                            <span aria-hidden="true" className="hidden md:block h-[2px] w-8 bg-[--color-accent]" />
                            <div className="space-y-2">
                                <h1 className="font-display text-2xl text-ink tracking-tight">
                                    What can I help you organize?
                                </h1>
                                <p className="text-base text-muted">
                                    Ask for a task, a note, or a list — I'll draft it for you to confirm.
                                </p>
                            </div>
                            <div className="flex flex-wrap justify-center gap-2 pt-1">
                                {EXAMPLE_PROMPTS.map((prompt) => (
                                    <Chip
                                        key={prompt}
                                        variant="action"
                                        onClick={() => {
                                            setInput(prompt);
                                            inputRef.current?.focus();
                                        }}
                                    >
                                        {prompt}
                                    </Chip>
                                ))}
                            </div>
                        </div>
                    </div>
                )}

                {/* Conversation */}
                {hasStarted && (
                    <div
                        ref={scrollRef}
                        className="flex-1 overflow-y-auto p-4 md:p-8 z-10 space-y-6 w-full max-w-3xl mx-auto"
                    >
                        {logs.map((msg, idx) => {
                            if (msg.role === 'user') {
                                return (
                                    <div key={idx} className="flex w-full justify-end">
                                        <div className="bg-ink text-paper rounded-2xl rounded-br-sm px-5 py-3 text-base leading-relaxed max-w-[640px] whitespace-pre-wrap">
                                            {msg.content}
                                        </div>
                                    </div>
                                );
                            }
                            if (msg.role === 'success') {
                                return (
                                    <ChatSuccessRow
                                        key={idx}
                                        entry={msg}
                                        logIndex={idx}
                                        onApplyEdit={applyInlineEdit}
                                    />
                                );
                            }
                            // system / AI prose — no bubble, plain prose left-aligned
                            return (
                                <div
                                    key={idx}
                                    className="text-ink-soft text-base leading-relaxed max-w-[640px] whitespace-pre-wrap"
                                >
                                    {msg.content}
                                </div>
                            );
                        })}

                        {pendingDrafts.length > 0 && (
                            <div className="space-y-3 max-w-[640px]">
                                {pendingDrafts.map((draft) => (
                                    <DraftPreviewCard
                                        key={draft.id}
                                        draft={draft}
                                        onConfirm={confirmDraft}
                                        onReject={rejectDraft}
                                        isProcessing={isProcessing}
                                    />
                                ))}
                            </div>
                        )}

                        {isProcessing && (
                            <div className="flex w-full justify-start">
                                <div className="flex items-center gap-1.5 py-2">
                                    <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '0ms' }} />
                                    <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '150ms' }} />
                                    <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '300ms' }} />
                                </div>
                            </div>
                        )}
                    </div>
                )}

                {/* Input bar */}
                <div
                    className="z-20 p-4 w-full"
                    style={{
                        paddingBottom: isMobile
                            ? `calc(1.5rem + env(safe-area-inset-bottom, 0px) + ${bottomOffset}px)`
                            : `calc(1rem + ${bottomOffset}px)`,
                    }}
                >
                    {!hasStarted && (
                        <p className="md:hidden text-xs text-muted text-center mb-3 px-4">
                            Try "Remind me to call Mom tomorrow" or "Create a shopping list with milk and eggs"
                        </p>
                    )}
                    <div className="max-w-3xl mx-auto">
                        <div
                            className={
                                'bg-surface border rounded-2xl p-2 transition-shadow duration-200 ease-out flex items-end gap-2 ' +
                                'border-border shadow-sm ' +
                                'focus-within:border-[--color-accent] focus-within:shadow-md focus-within:ring-2 focus-within:ring-[--color-accent-ring]'
                            }
                        >
                            <textarea
                                ref={inputRef}
                                value={input}
                                onChange={(e) => setInput(e.target.value)}
                                onKeyDown={handleKeyDown}
                                placeholder="Ask anything…"
                                rows={1}
                                className="flex-1 max-h-32 min-h-[40px] py-2 px-3 bg-transparent outline-none text-base leading-relaxed text-ink placeholder:text-muted-soft resize-none font-sans"
                            />
                            <div className="flex items-center gap-1">
                                {speech.isSupported && (
                                    <button
                                        type="button"
                                        onClick={speech.toggle}
                                        title={speech.isListening ? 'Stop voice input' : 'Voice input'}
                                        className={
                                            'h-10 w-10 inline-flex items-center justify-center rounded-lg transition-colors duration-150 ease-out ' +
                                            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
                                            (speech.isListening
                                                ? 'bg-danger-soft text-danger'
                                                : 'text-muted hover:bg-paper-2 hover:text-ink')
                                        }
                                    >
                                        {speech.isListening
                                            ? <Square size={18} strokeWidth={1.75} aria-hidden="true" />
                                            : <Mic size={18} strokeWidth={1.75} aria-hidden="true" />}
                                    </button>
                                )}

                                <button
                                    type="button"
                                    onClick={handleSend}
                                    disabled={!input.trim() || isProcessing}
                                    title="Send"
                                    className={
                                        'h-10 w-10 inline-flex items-center justify-center rounded-lg transition-colors duration-150 ease-out ' +
                                        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
                                        'bg-ink text-paper hover:bg-ink-soft ' +
                                        'disabled:bg-paper-2 disabled:text-muted-soft disabled:cursor-not-allowed'
                                    }
                                >
                                    <ArrowUp size={18} strokeWidth={1.75} aria-hidden="true" />
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}
