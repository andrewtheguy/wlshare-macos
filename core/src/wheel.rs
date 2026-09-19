//! Scrolling, which RFB has no word for.
//!
//! There are no scroll events in RFB: a wheel notch is a button press and
//! release on one of four buttons above the three real ones, and the server
//! turns each press into one discrete axis event. A Mac does not have notches.
//! A mouse wheel arrives as whole lines, and a trackpad as a stream of points
//! several hundred of which make a gesture, so both have to be gathered up into
//! notches, and the leftovers kept for the next event or a slow drag scrolls
//! nothing at all.

pub use wlshare_client::{WHEEL_DOWN, WHEEL_LEFT, WHEEL_RIGHT, WHEEL_UP};

/// Points of a precise (trackpad or Magic Mouse) scroll that make one notch.
/// AppKit measures those in points of content, and three lines of text is about
/// this far.
const POINTS_PER_NOTCH: f64 = 12.0;

/// The most notches one event may turn into. A flick on a trackpad is a large
/// delta and a momentum scroll is a long run of them; past this the desktop is
/// scrolling faster than anyone reads, and each notch is a round trip.
const MAX_NOTCHES: usize = 16;

/// The leftovers of scrolls too small to be a notch yet.
#[derive(Debug, Default)]
pub struct Wheel {
    horizontal: f64,
    vertical: f64,
}

impl Wheel {
    /// The wheel buttons a scroll comes to, in the order they should be
    /// clicked. `dx` and `dy` are AppKit's `scrollingDeltaX`/`Y` — positive `dy`
    /// is a scroll up and positive `dx` a scroll left — and `precise` is its
    /// `hasPreciseScrollingDeltas`, which says whether they are points or lines.
    pub fn scroll(&mut self, dx: f64, dy: f64, precise: bool) -> Vec<u8> {
        let per_notch = if precise { POINTS_PER_NOTCH } else { 1.0 };
        let mut notches = Vec::new();
        // Vertical first: a scroll that is both is mostly vertical, and the
        // order is what the desktop sees.
        Self::gather(&mut self.vertical, dy / per_notch, WHEEL_UP, WHEEL_DOWN, &mut notches);
        Self::gather(&mut self.horizontal, dx / per_notch, WHEEL_LEFT, WHEEL_RIGHT, &mut notches);
        notches
    }

    fn gather(carried: &mut f64, delta: f64, positive: u8, negative: u8, out: &mut Vec<u8>) {
        if delta == 0.0 {
            return;
        }
        // A reversal throws away what was carried: half a notch one way is not
        // half a notch back the other, and keeping it swallows the first flick
        // of every change of direction.
        if carried.signum() != delta.signum() {
            *carried = 0.0;
        }
        *carried += delta;
        let button = if delta > 0.0 { positive } else { negative };
        while carried.abs() >= 1.0 && out.len() < MAX_NOTCHES {
            *carried -= carried.signum();
            out.push(button);
        }
        // Past the cap the rest is dropped rather than saved up, or a flick
        // would keep scrolling long after the finger stopped.
        if out.len() >= MAX_NOTCHES {
            *carried = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_of_a_mouse_wheel_is_a_notch() {
        let mut wheel = Wheel::default();
        assert_eq!(wheel.scroll(0.0, 1.0, false), vec![WHEEL_UP]);
        assert_eq!(wheel.scroll(0.0, -1.0, false), vec![WHEEL_DOWN]);
        assert_eq!(wheel.scroll(0.0, 3.0, false), vec![WHEEL_UP; 3]);
        assert_eq!(wheel.scroll(-2.0, 0.0, false), vec![WHEEL_RIGHT; 2]);
        assert_eq!(wheel.scroll(2.0, 0.0, false), vec![WHEEL_LEFT; 2]);
    }

    #[test]
    fn a_trackpad_gathers_points_until_they_are_a_notch() {
        let mut wheel = Wheel::default();
        let mut sent = Vec::new();
        for _ in 0..12 {
            sent.extend(wheel.scroll(0.0, 1.0, true));
        }
        assert_eq!(sent, vec![WHEEL_UP], "twelve points is one notch, not twelve and not none");

        // And the leftovers carry: another eleven points is the next notch.
        let mut sent = Vec::new();
        for _ in 0..11 {
            sent.extend(wheel.scroll(0.0, 1.0, true));
        }
        assert_eq!(sent, Vec::<u8>::new());
        assert_eq!(wheel.scroll(0.0, 1.0, true), vec![WHEEL_UP]);
    }

    #[test]
    fn turning_back_does_not_have_to_undo_what_was_carried() {
        let mut wheel = Wheel::default();
        assert_eq!(wheel.scroll(0.0, 11.0, true), Vec::<u8>::new());
        // Without the reversal rule this would need eleven points of the other
        // way before the first notch down.
        assert_eq!(wheel.scroll(0.0, -12.0, true), vec![WHEEL_DOWN]);
    }

    #[test]
    fn both_axes_at_once_go_vertical_first() {
        let mut wheel = Wheel::default();
        assert_eq!(wheel.scroll(2.0, -1.0, false), vec![WHEEL_DOWN, WHEEL_LEFT, WHEEL_LEFT]);
    }

    #[test]
    fn a_flick_is_capped_and_leaves_nothing_saved_up() {
        let mut wheel = Wheel::default();
        let notches = wheel.scroll(0.0, 4000.0, true);
        assert_eq!(notches.len(), MAX_NOTCHES);
        assert!(notches.iter().all(|b| *b == WHEEL_UP));
        // The overflow is gone, not waiting for the next event.
        assert_eq!(wheel.scroll(0.0, 1.0, true), Vec::<u8>::new());
    }

    #[test]
    fn a_scroll_of_nothing_is_nothing() {
        let mut wheel = Wheel::default();
        assert_eq!(wheel.scroll(0.0, 0.0, true), Vec::<u8>::new());
        assert_eq!(wheel.scroll(0.0, 0.0, false), Vec::<u8>::new());
    }
}
