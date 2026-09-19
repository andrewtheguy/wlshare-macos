//! The wlshare client's macOS half, under the AppKit app.
//!
//! The session itself — the socket, the RFB session, the decoders, the
//! framebuffer, the pointer's shape, the clipboard and the sound — is
//! `wlshare-client`, the crate the Windows app is built on too, from the wlshare
//! repository's release tag. What is here is what is about the Mac: the table
//! that says what a Mac key is on the wire ([`keysym`]), the gathering of a
//! Mac's scrolls into notches ([`wheel`]), and the C ABI the app links
//! ([`ffi`]).

pub mod ffi;
pub mod keysym;
pub mod wheel;

use std::ops::Deref;
use std::sync::Mutex;

pub use wheel::Wheel;
pub use wlshare_client::*;

/// A session, and what is left over of the scrolls given to it.
///
/// It is a [`wlshare_client::Client`] — everything that one does, this does
/// through it — with the one piece of state that is the Mac's: a scroll too
/// small to be a notch yet is kept here for the next one.
pub struct Client {
    session: wlshare_client::Client,
    wheel: Mutex<Wheel>,
}

impl Client {
    /// Start a session ([`wlshare_client::Client::connect`]).
    pub fn connect(config: Config, surface: Surface) -> Self {
        Self { session: wlshare_client::Client::connect(config, surface), wheel: Mutex::new(Wheel::default()) }
    }

    /// The wheel notches a scroll comes to ([`Wheel::scroll`]), gathered across
    /// events. Each is a button the caller clicks — press with the buttons it
    /// already holds, then release.
    pub fn wheel(&self, dx: f64, dy: f64, precise: bool) -> Vec<u8> {
        self.wheel.lock().unwrap().scroll(dx, dy, precise)
    }
}

impl Deref for Client {
    type Target = wlshare_client::Client;

    fn deref(&self) -> &Self::Target {
        &self.session
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scroll_is_gathered_across_events_on_the_client() {
        // Port 0 never connects; the wheel is the client's and needs no desktop.
        let config = Config { host: "127.0.0.1".to_owned(), port: 0, username: String::new(), password: String::new(), audio: false, encoding: Encoding::Zrle };
        let client = Client::connect(config, Surface { width: 800, height: 600, scale: 2.0 });
        assert_eq!(client.wheel(0.0, 1.0, false), vec![WHEEL_UP]);
    }
}
