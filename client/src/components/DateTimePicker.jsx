import { useState, useRef } from 'react';
import { LocalizationProvider } from '@mui/x-date-pickers/LocalizationProvider';
import { AdapterDayjs } from '@mui/x-date-pickers/AdapterDayjs';
import { DateTimePicker as MuiDateTimePicker } from '@mui/x-date-pickers/DateTimePicker';
import { createTheme, ThemeProvider } from '@mui/material/styles';
import dayjs from 'dayjs';
import { Calendar } from 'lucide-react';

// Custom theme to match the app's design
const theme = createTheme({
    palette: {
        primary: {
            main: '#6366f1', // indigo-500
        },
    },
    components: {
        MuiButton: {
            styleOverrides: {
                root: {
                    textTransform: 'none',
                    fontWeight: 500,
                    borderRadius: '6px',
                    padding: '6px 16px',
                    fontSize: '0.875rem',
                },
            },
        },
    },
});

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
        <ThemeProvider theme={theme}>
            <LocalizationProvider dateAdapter={AdapterDayjs}>
                <div className={inline ? 'inline-block' : 'w-full'}>
                    {/* Custom trigger button */}
                    {inline ? (
                        <button
                            ref={anchorRef}
                            type="button"
                            onClick={handleOpen}
                            className={`inline-flex items-center gap-1 hover:bg-slate-100 rounded px-1 py-0.5 transition-colors text-xs cursor-pointer ${dateColorClass || 'text-slate-400'}`}
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
                            className="w-full px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent text-sm text-left flex items-center justify-between bg-white hover:bg-slate-50 transition-colors cursor-pointer"
                        >
                            <span className={`whitespace-nowrap truncate ${displayValue ? 'text-gray-900' : 'text-gray-400'}`}>
                                {displayValue || placeholder || 'Select Date'}
                            </span>
                            <Calendar size={16} className="text-gray-400 flex-shrink-0 ml-2" />
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
                                        border: '1px solid #e2e8f0',
                                        marginTop: '4px',
                                        overflow: 'hidden',
                                    },
                                    // Action bar styling
                                    '& .MuiDialogActions-root': {
                                        backgroundColor: '#f8fafc',
                                        borderTop: '1px solid #e2e8f0',
                                        padding: '12px 16px',
                                        gap: '8px',
                                    },
                                    // Clear button - subtle gray text
                                    '& .MuiDialogActions-root .MuiButton-root:first-of-type': {
                                        color: '#64748b',
                                        '&:hover': {
                                            backgroundColor: '#f1f5f9',
                                        },
                                    },
                                    // Cancel button - outline style
                                    '& .MuiDialogActions-root .MuiButton-root:nth-of-type(2)': {
                                        border: '1px solid #e2e8f0',
                                        color: '#64748b',
                                        backgroundColor: 'white',
                                        '&:hover': {
                                            backgroundColor: '#f8fafc',
                                            borderColor: '#cbd5e1',
                                        },
                                    },
                                    // OK/Accept button - solid indigo
                                    '& .MuiDialogActions-root .MuiButton-root:last-of-type': {
                                        backgroundColor: '#6366f1',
                                        color: 'white',
                                        '&:hover': {
                                            backgroundColor: '#4f46e5',
                                        },
                                    },
                                    // When only 2 buttons (cancel, accept) - adjust styles
                                    '& .MuiDialogActions-root:has(.MuiButton-root:nth-of-type(2):last-of-type) .MuiButton-root:first-of-type': {
                                        border: '1px solid #e2e8f0',
                                        color: '#64748b',
                                        backgroundColor: 'white',
                                        '&:hover': {
                                            backgroundColor: '#f8fafc',
                                            borderColor: '#cbd5e1',
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
        </ThemeProvider>
    );
}
