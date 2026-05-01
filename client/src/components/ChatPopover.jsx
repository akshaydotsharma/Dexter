import { useEffect, useRef, useState } from 'react';
import { ArrowUp, Mic, Sparkles, Square, X } from 'lucide-react';
import ChatSuccessRow from './ChatSuccessRow';
import DraftPreviewCard from './DraftPreviewCard';
import useChat from '../hooks/useChat';
import useSpeechRecognition from '../hooks/useSpeechRecognition';

/**
 * v2 ChatPopover — the floating chat surface that appears on every route
 * except /chat. Shares state machine with ChatPage via useChat (the
 * popover keeps its own instance — conversation history is separate from
 * the full-page chat by design, both are scratch surfaces today).
 */
export default function ChatPopover({ isOpen, onClose, onDraftConfirmed }) {
    const {
        logs,
        pendingDrafts,
        isProcessing,
        send,
        confirmDraft,
        rejectDraft,
        applyInlineEdit,
    } = useChat();
    const speech = useSpeechRecognition();

    const [input, setInput] = useState('');
    const scrollRef = useRef(null);
    const textareaRef = useRef(null);

    useEffect(() => {
        const el = scrollRef.current;
        if (!el) return;
        const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
        el.scrollTo({ top: el.scrollHeight, behavior: reduced ? 'auto' : 'smooth' });
    }, [logs, pendingDrafts.length, isProcessing]);

    useEffect(() => {
        speech.onTranscript((transcript) => {
            setInput((prev) => (prev ? `${prev} ${transcript}` : transcript));
        });
    }, [speech]);

    useEffect(() => {
        if (isOpen) {
            const id = window.setTimeout(() => textareaRef.current?.focus(), 60);
            return () => window.clearTimeout(id);
        }
    }, [isOpen]);

    if (!isOpen) return null;

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

    const handleConfirm = async (draftId, updatedData) => {
        const outcome = await confirmDraft(draftId, updatedData);
        if (outcome?.success && onDraftConfirmed) {
            onDraftConfirmed(outcome.result);
        }
    };

    const isEmpty = logs.length === 0 && pendingDrafts.length === 0;

    return (
        <>
            {/* Backdrop */}
            <div
                className="fixed inset-0 bg-ink/20 z-40 motion-safe:animate-in motion-safe:fade-in motion-safe:duration-200"
                onClick={onClose}
                aria-hidden="true"
            />

            {/* Popover */}
            <div
                role="dialog"
                aria-label="AI Assistant"
                className="fixed bottom-8 right-8 w-[380px] h-[560px] bg-surface border border-border rounded-2xl shadow-md z-50 flex flex-col overflow-hidden motion-safe:animate-in motion-safe:slide-in-from-bottom-4 motion-safe:fade-in motion-safe:duration-200"
            >
                {/* Header */}
                <div className="bg-paper-2 border-b border-border h-12 px-4 flex items-center justify-between flex-shrink-0">
                    <div className="flex items-center gap-2">
                        <span aria-hidden="true" className="w-2 h-2 rounded-full bg-[--color-accent]" />
                        <h2 className="font-display text-base text-ink">AI Assistant</h2>
                    </div>
                    <button
                        type="button"
                        onClick={onClose}
                        aria-label="Close chat"
                        title="Close"
                        className="h-8 w-8 inline-flex items-center justify-center rounded-lg text-muted hover:bg-paper-2 hover:text-ink transition-colors duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]"
                    >
                        <X size={16} strokeWidth={1.75} aria-hidden="true" />
                    </button>
                </div>

                {/* Body */}
                <div ref={scrollRef} className="flex-1 overflow-y-auto bg-paper p-4 space-y-4">
                    {isEmpty ? (
                        <div className="h-full flex flex-col items-center justify-center text-center px-6 space-y-3">
                            <Sparkles size={28} strokeWidth={1.75} className="text-muted" aria-hidden="true" />
                            <p className="font-display text-base text-ink">Start a conversation</p>
                            <p className="text-xs text-muted leading-relaxed">
                                Try &ldquo;todo Buy milk&rdquo; or &ldquo;note Meeting notes&rdquo;
                            </p>
                        </div>
                    ) : (
                        <>
                            {logs.map((msg, idx) => {
                                if (msg.role === 'user') {
                                    return (
                                        <div key={idx} className="flex w-full justify-end">
                                            <div className="bg-ink text-paper rounded-2xl rounded-br-sm px-3.5 py-2 text-sm max-w-[280px] whitespace-pre-wrap">
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
                                            onLinkClick={() => onClose?.()}
                                        />
                                    );
                                }
                                return (
                                    <div key={idx} className="flex w-full justify-start">
                                        <div className="bg-paper-2 text-ink-soft rounded-2xl rounded-bl-sm px-3.5 py-2 text-sm max-w-[280px] whitespace-pre-wrap">
                                            {msg.content}
                                        </div>
                                    </div>
                                );
                            })}

                            {pendingDrafts.length > 0 && (
                                <div className="space-y-3">
                                    {pendingDrafts.map((draft) => (
                                        <DraftPreviewCard
                                            key={draft.id}
                                            draft={draft}
                                            onConfirm={handleConfirm}
                                            onReject={rejectDraft}
                                            isProcessing={isProcessing}
                                        />
                                    ))}
                                </div>
                            )}

                            {isProcessing && (
                                <div className="flex w-full justify-start">
                                    <div className="bg-paper-2 px-3.5 py-2 rounded-2xl rounded-bl-sm flex items-center gap-1.5">
                                        <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '0ms' }} />
                                        <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '150ms' }} />
                                        <span className="w-1.5 h-1.5 rounded-full bg-muted motion-safe:animate-bounce" style={{ animationDelay: '300ms' }} />
                                    </div>
                                </div>
                            )}
                        </>
                    )}
                </div>

                {/* Input bar */}
                <div className="border-t border-border bg-surface p-3 flex-shrink-0">
                    <div
                        className={
                            'bg-surface border rounded-xl p-1.5 transition-shadow duration-200 ease-out flex items-end gap-1 ' +
                            'border-border ' +
                            'focus-within:border-[--color-accent] focus-within:shadow-sm focus-within:ring-2 focus-within:ring-[--color-accent-ring]'
                        }
                    >
                        <textarea
                            ref={textareaRef}
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={handleKeyDown}
                            placeholder="Ask anything…"
                            rows={1}
                            className="flex-1 max-h-24 min-h-[36px] py-1.5 px-2 bg-transparent outline-none text-sm leading-relaxed text-ink placeholder:text-muted-soft resize-none"
                        />
                        <div className="flex items-center gap-1">
                            {speech.isSupported && (
                                <button
                                    type="button"
                                    onClick={speech.toggle}
                                    title={speech.isListening ? 'Stop voice input' : 'Voice input'}
                                    className={
                                        'h-9 w-9 inline-flex items-center justify-center rounded-lg transition-colors duration-150 ease-out ' +
                                        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
                                        (speech.isListening
                                            ? 'bg-danger-soft text-danger'
                                            : 'text-muted hover:bg-paper-2 hover:text-ink')
                                    }
                                >
                                    {speech.isListening
                                        ? <Square size={16} strokeWidth={1.75} aria-hidden="true" />
                                        : <Mic size={16} strokeWidth={1.75} aria-hidden="true" />}
                                </button>
                            )}
                            <button
                                type="button"
                                onClick={handleSend}
                                disabled={!input.trim() || isProcessing}
                                title="Send"
                                className={
                                    'h-9 w-9 inline-flex items-center justify-center rounded-lg transition-colors duration-150 ease-out ' +
                                    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--color-accent-ring] ' +
                                    'bg-ink text-paper hover:bg-ink-soft ' +
                                    'disabled:bg-paper-2 disabled:text-muted-soft disabled:cursor-not-allowed'
                                }
                            >
                                <ArrowUp size={16} strokeWidth={1.75} aria-hidden="true" />
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </>
    );
}
