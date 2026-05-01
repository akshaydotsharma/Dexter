import { useEffect, useRef, useState, useCallback } from 'react';

/**
 * useSpeechRecognition — thin wrapper around the webkit SpeechRecognition
 * API. Both the full-page chat and the popover use this so the mic UX
 * stays identical across surfaces.
 *
 * Returns:
 *   isListening  — boolean
 *   isSupported  — boolean (false on browsers that don't expose the API)
 *   toggle       — start/stop listening
 *   onTranscript — register a callback that receives the recognized text
 */
function detectSupport() {
  if (typeof window === 'undefined') return false;
  return 'webkitSpeechRecognition' in window;
}

export default function useSpeechRecognition() {
  const recognitionRef = useRef(null);
  const callbackRef = useRef(null);
  // Lazy-init so we never call setState() in an effect body just to flip
  // the support flag — react-hooks/set-state-in-effect lints that pattern.
  const [isSupported] = useState(detectSupport);
  const [isListening, setIsListening] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!isSupported) return undefined;

    const recognition = new window.webkitSpeechRecognition();
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.lang = 'en-US';

    recognition.onstart = () => setIsListening(true);
    recognition.onend = () => setIsListening(false);
    recognition.onerror = (event) => {
      setIsListening(false);
      setError(event.error);
    };
    recognition.onresult = (event) => {
      const transcript = event.results[0][0].transcript;
      if (callbackRef.current) callbackRef.current(transcript);
    };

    recognitionRef.current = recognition;

    return () => {
      try {
        recognition.stop();
      } catch {
        // already stopped
      }
      recognitionRef.current = null;
    };
  }, [isSupported]);

  const onTranscript = useCallback((cb) => {
    callbackRef.current = cb;
  }, []);

  const toggle = useCallback(() => {
    const r = recognitionRef.current;
    if (!r) return;
    if (isListening) {
      r.stop();
    } else {
      setError(null);
      r.start();
    }
  }, [isListening]);

  return { isListening, isSupported, toggle, onTranscript, error };
}
