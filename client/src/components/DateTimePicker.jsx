import { useState, useRef } from 'react';
import { LocalizationProvider } from '@mui/x-date-pickers/LocalizationProvider';
import { AdapterDayjs } from '@mui/x-date-pickers/AdapterDayjs';
import { DateTimePicker as MuiDateTimePicker } from '@mui/x-date-pickers/DateTimePicker';
import dayjs from 'dayjs';
import { Calendar } from 'lucide-react';

export default function DateTimePicker({
    value,
    onChange,
    onCancel,
    placeholder = 'Select Date',
    inline = false,
    dateColorClass = ''
}) {
    const [isOpen, setIsOpen] = useState(false);
    const [tempDate, setTempDate] = useState(value ? dayjs(value) : null);
    const anchorRef = useRef(null);

    const handleOpen = () => {
        setTempDate(value ? dayjs(value) : null);
        setIsOpen(true);
    };

    const handleClose = () => {
        setIsOpen(false);
        onCancel?.();
    };

    const handleAccept = (newValue) => {
        onChange(newValue ? newValue.toISOString() : '');
        setIsOpen(false);
    };

    const formatDisplayValue = (date) => {
        if (!date) return '';
        const d = dayjs(date);
        return d.format('MMM D, h:mm A');
    };

    const displayValue = formatDisplayValue(value);

    return (
            <LocalizationProvider dateAdapter={AdapterDayjs}>
                <div className={inline ? 'inline-block' : 'w-full'}>
                    {/* Custom trigger button */}
                    {inline ? (
                        <button
                            ref={anchorRef}
                            type="button"
                            onClick={handleOpen}
                            className={`inline-flex items-center gap-1 hover:bg-paper-2 rounded px-1 py-0.5 transition-colors text-xs cursor-pointer ${dateColorClass || 'text-muted-soft'}`}
                            title="Click to change date"
                        >
                            <Calendar size={12} />
                            {displayValue || placeholder || 'No Due Date'}
                        </button>
                    ) : (
                        <button
                            ref={anchorRef}
                            type="button"
                            onClick={handleOpen}
                            className="w-full px-3 py-2 border border-border rounded-lg focus:outline-none focus:ring-2 focus:ring-[--color-accent-ring] focus:border-transparent text-sm text-left flex items-center justify-between bg-surface hover:bg-paper-2 transition-colors cursor-pointer"
                        >
                            <span className={`whitespace-nowrap truncate ${displayValue ? 'text-ink' : 'text-muted-soft'}`}>
                                {displayValue || placeholder || 'Select Date'}
                            </span>
                            <Calendar size={16} className="text-muted-soft flex-shrink-0 ml-2" />
                        </button>
                    )}

                    {/* MUI DateTimePicker - hidden input, only shows popper */}
                    <MuiDateTimePicker
                        open={isOpen}
                        onClose={handleClose}
                        onAccept={handleAccept}
                        value={tempDate}
                        onChange={(newValue) => setTempDate(newValue)}
                        slotProps={{
                            popper: {
                                anchorEl: anchorRef.current,
                                placement: 'bottom-start',
                                sx: {
                                    zIndex: 9999,
                                    '& .MuiPaper-root': {
                                        borderRadius: '0.75rem',
                                        boxShadow: '0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)',
                                        border: '1px solid var(--color-border)',
                                        backgroundColor: 'var(--color-surface)',
                                        color: 'var(--color-ink)',
                                        marginTop: '4px',
                                        overflow: 'hidden',
                                    },
                                    '& .MuiDialogActions-root': {
                                        backgroundColor: 'var(--color-paper-2)',
                                        borderTop: '1px solid var(--color-border)',
                                        padding: '12px 16px',
                                        gap: '8px',
                                    },
                                    '& .MuiDialogActions-root .MuiButton-root:first-of-type': {
                                        color: 'var(--color-muted)',
                                        '&:hover': {
                                            backgroundColor: 'var(--color-paper-2)',
                                        },
                                    },
                                    '& .MuiDialogActions-root .MuiButton-root:nth-of-type(2)': {
                                        border: '1px solid var(--color-border)',
                                        color: 'var(--color-ink-soft)',
                                        backgroundColor: 'var(--color-surface)',
                                        '&:hover': {
                                            backgroundColor: 'var(--color-paper-2)',
                                            borderColor: 'var(--color-border-strong)',
                                        },
                                    },
                                    '& .MuiDialogActions-root .MuiButton-root:last-of-type': {
                                        backgroundColor: 'var(--color-ink)',
                                        color: 'var(--color-paper)',
                                        '&:hover': {
                                            backgroundColor: 'var(--color-ink-soft)',
                                        },
                                    },
                                    '& .MuiDialogActions-root:has(.MuiButton-root:nth-of-type(2):last-of-type) .MuiButton-root:first-of-type': {
                                        border: '1px solid var(--color-border)',
                                        color: 'var(--color-ink-soft)',
                                        backgroundColor: 'var(--color-surface)',
                                        '&:hover': {
                                            backgroundColor: 'var(--color-paper-2)',
                                            borderColor: 'var(--color-border-strong)',
                                        },
                                    },
                                },
                            },
                            actionBar: {
                                actions: value ? ['clear', 'cancel', 'accept'] : ['cancel', 'accept'],
                            },
                            field: {
                                sx: { display: 'none' },
                            },
                            textField: {
                                sx: {
                                    display: 'none',
                                    width: 0,
                                    height: 0,
                                    overflow: 'hidden',
                                },
                            },
                        }}
                        closeOnSelect={false}
                    />
                </div>
            </LocalizationProvider>
    );
}
