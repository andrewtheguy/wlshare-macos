//! What a Mac key press is on the wire.
//!
//! RFB carries X11 keysyms, so every key the window sees has to become one. The
//! translation is here rather than in the app for the reason every other
//! decision is: it is a table, tables go wrong quietly, and a table in Rust has
//! tests.
//!
//! Two kinds of key, and the order matters. A key that *names* itself — an
//! arrow, a function key, Escape, a keypad digit, a modifier — has a keysym of
//! its own and is found by its macOS virtual key code, whatever character macOS
//! says it typed; that is what makes the keypad's `1` arrive as `KP_1` and not
//! as a plain `1`. Every other key is a character key, and its keysym is the
//! character the app already resolved — the case included, because the server
//! takes a character keysym as a character already cased and presses Shift
//! around the keycode to make it come out that way.
//!
//! The character wanted is AppKit's `charactersIgnoringModifiers` cased by
//! Shift and Caps Lock, not `characters`: the latter turns Control-A into U+0001
//! and Option-N into a dead key, neither of which is the key that was pressed.

/// A macOS virtual key code (`kVK_*`, as `NSEvent.keyCode` gives it) and the
/// X11 keysym it always means, whatever it types.
///
/// Sorted by key code so the table reads as the keyboard is numbered, not as
/// X11 orders its keysyms.
const NAMED: &[(u16, u32)] = &[
    (0x24, 0xff0d), // Return
    (0x30, 0xff09), // Tab
    (0x33, 0xff08), // Delete, which is X11's BackSpace
    (0x35, 0xff1b), // Escape
    (0x36, 0xffec), // Right Command -> Super_R
    (0x37, 0xffeb), // Command -> Super_L
    (0x38, 0xffe1), // Shift_L
    (0x39, 0xffe5), // Caps_Lock
    (0x3a, 0xffe9), // Option -> Alt_L
    (0x3b, 0xffe3), // Control_L
    (0x3c, 0xffe2), // Shift_R
    (0x3d, 0xffea), // Right Option -> Alt_R
    (0x3e, 0xffe4), // Control_R
    (0x40, 0xffce), // F17
    (0x41, 0xffae), // KP_Decimal
    (0x43, 0xffaa), // KP_Multiply
    (0x45, 0xffab), // KP_Add
    (0x47, 0xff7f), // Keypad Clear -> Num_Lock, where that key sits on a PC
    (0x4b, 0xffaf), // KP_Divide
    (0x4c, 0xff8d), // KP_Enter
    (0x4e, 0xffad), // KP_Subtract
    (0x4f, 0xffcf), // F18
    (0x50, 0xffd0), // F19
    (0x51, 0xffbd), // KP_Equal
    (0x52, 0xffb0), // KP_0
    (0x53, 0xffb1), // KP_1
    (0x54, 0xffb2), // KP_2
    (0x55, 0xffb3), // KP_3
    (0x56, 0xffb4), // KP_4
    (0x57, 0xffb5), // KP_5
    (0x58, 0xffb6), // KP_6
    (0x59, 0xffb7), // KP_7
    (0x5a, 0xffd1), // F20
    (0x5b, 0xffb8), // KP_8
    (0x5c, 0xffb9), // KP_9
    (0x60, 0xffc2), // F5
    (0x61, 0xffc3), // F6
    (0x62, 0xffc4), // F7
    (0x63, 0xffc0), // F3
    (0x64, 0xffc5), // F8
    (0x65, 0xffc6), // F9
    (0x67, 0xffc8), // F11
    (0x69, 0xffca), // F13
    (0x6a, 0xffcd), // F16
    (0x6b, 0xffcb), // F14
    (0x6d, 0xffc7), // F10
    (0x6f, 0xffc9), // F12
    (0x71, 0xffcc), // F15
    (0x72, 0xff63), // Help, which is X11's Insert on the key that sits there
    (0x73, 0xff50), // Home
    (0x74, 0xff55), // Page_Up
    (0x75, 0xffff), // Forward Delete, which is X11's Delete
    (0x76, 0xffc1), // F4
    (0x77, 0xff57), // End
    (0x78, 0xffbf), // F2
    (0x79, 0xff56), // Page_Down
    (0x7a, 0xffbe), // F1
    (0x7b, 0xff51), // Left
    (0x7c, 0xff53), // Right
    (0x7d, 0xff54), // Down
    (0x7e, 0xff52), // Up
];

/// The keysym a key code always means, if it is one that names itself.
pub fn named(key_code: u16) -> Option<u32> {
    NAMED.iter().find(|(code, _)| *code == key_code).map(|(_, keysym)| *keysym)
}

/// The keysym for a character, RFC 6143 §7.5.4's rule: Latin-1 is itself, and
/// everything else is Unicode with the high bit of the keysym space set.
/// A control character is not a key and has none — the app is meant to send
/// what the key types with Control let go, which is a printable one.
pub fn of_char(c: char) -> Option<u32> {
    match u32::from(c) {
        0x20..=0x7e | 0xa0..=0xff => Some(u32::from(c)),
        0x00..=0x1f | 0x7f..=0x9f => None,
        other => Some(0x0100_0000 + other),
    }
}

/// The keysym for a key press: what the key names, or failing that what it
/// typed. `None` is a key with neither, which is not sent.
pub fn keysym(key_code: u16, character: Option<char>) -> Option<u32> {
    named(key_code).or_else(|| character.and_then(of_char))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_that_names_itself_beats_whatever_it_typed() {
        // The keypad's 1 types '1' and is still KP_1.
        assert_eq!(keysym(0x53, Some('1')), Some(0xffb1));
        // Return types a carriage return, which of_char refuses on its own.
        assert_eq!(keysym(0x24, Some('\r')), Some(0xff0d));
        assert_eq!(keysym(0x7e, None), Some(0xff52));
    }

    #[test]
    fn a_character_key_carries_the_case_the_app_resolved() {
        // The same key code, shifted and not: the server presses Shift to match.
        assert_eq!(keysym(0x00, Some('a')), Some(0x61));
        assert_eq!(keysym(0x00, Some('A')), Some(0x41));
        assert_eq!(keysym(0x1d, Some('0')), Some(0x30));
        assert_eq!(keysym(0x18, Some('+')), Some(0x2b));
    }

    #[test]
    fn latin_1_is_itself_and_the_rest_is_unicode() {
        assert_eq!(of_char(' '), Some(0x20));
        assert_eq!(of_char('~'), Some(0x7e));
        assert_eq!(of_char('é'), Some(0xe9));
        assert_eq!(of_char('ÿ'), Some(0xff));
        // Just past Latin-1, and well past it.
        assert_eq!(of_char('Ā'), Some(0x0100_0100));
        assert_eq!(of_char('中'), Some(0x0100_4e2d));
        assert_eq!(of_char('😀'), Some(0x0101_f600));
    }

    #[test]
    fn a_control_character_is_not_a_key() {
        assert_eq!(of_char('\u{1}'), None);
        assert_eq!(of_char('\u{7f}'), None);
        assert_eq!(of_char('\u{9f}'), None);
        assert_eq!(keysym(0x00, Some('\u{1}')), None);
        assert_eq!(keysym(0xffff, None), None);
    }

    #[test]
    fn the_table_is_one_key_code_per_row_and_no_keysym_twice() {
        let mut codes: Vec<u16> = NAMED.iter().map(|(code, _)| *code).collect();
        let ordered = codes.clone();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), NAMED.len(), "a key code appears twice");
        assert_eq!(codes, ordered, "the table is not in key-code order");

        let mut keysyms: Vec<u32> = NAMED.iter().map(|(_, keysym)| *keysym).collect();
        keysyms.sort_unstable();
        keysyms.dedup();
        assert_eq!(keysyms.len(), NAMED.len(), "two key codes send the same keysym");
    }

    #[test]
    fn the_function_keys_are_the_run_x11_says_they_are() {
        // F1..F20 are consecutive from 0xffbe, and the Mac numbers them all over
        // the place — the one thing in this table worth checking as a sequence.
        let order = [0x7a, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6d, 0x67, 0x6f, 0x69, 0x6b, 0x71, 0x6a, 0x40, 0x4f, 0x50, 0x5a];
        for (n, code) in order.into_iter().enumerate() {
            assert_eq!(named(code), Some(0xffbe + n as u32), "F{} at key code {code:#04x}", n + 1);
        }
    }
}
