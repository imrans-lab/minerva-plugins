//! Signal-handler bridge. The handler performs only a lock-free atomic store;
//! normal dispatch owns all file, credential and child-process cleanup.
use std::sync::atomic::{AtomicBool, Ordering};
static REQUESTED: AtomicBool = AtomicBool::new(false);
extern "C" fn signal(_signal: i32) {
    REQUESTED.store(true, Ordering::Relaxed);
}
pub fn requested() -> bool {
    REQUESTED.load(Ordering::Relaxed)
}
pub fn install() -> Result<(), String> {
    // SAFETY: sigaction is plain C storage; sigemptyset initializes its mask.
    // The installed function has C signal ABI and touches only AtomicBool.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = signal as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                return Err("Cannot install controlled runtime shutdown handlers".into());
            }
        }
    }
    Ok(())
}
