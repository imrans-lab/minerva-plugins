//! Unix child ownership and CPU-time limits for the local slicer.
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod unix {
    use crate::error::{Error, Result};
    use std::io;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, ExitStatus};

    pub struct OwnedChild {
        child: Child,
        owned: bool,
    }
    impl OwnedChild {
        pub fn spawn(command: &mut Command) -> Result<Self> {
            command.process_group(0);
            // SAFETY: the child closure calls only async-signal-safe setrlimit
            // with a stack value, and reads errno on failure; no allocation/locks.
            unsafe {
                command.pre_exec(|| {
                    let limit = libc::rlimit {
                        rlim_cur: 20,
                        rlim_max: 20,
                    };
                    if libc::setrlimit(libc::RLIMIT_CPU, &limit) != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let child = command
                .spawn()
                .map_err(|_| Error::Io("Cannot start installed PrusaSlicer"))?;
            Ok(Self { child, owned: true })
        }
        pub fn id(&self) -> u32 {
            self.child.id()
        }
        pub fn exited(&mut self) -> Result<bool> {
            // SAFETY: siginfo_t is a C output record; zero is valid for its scalar
            // fields. waitid writes within the record and WNOWAIT retains ownership.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: this is the owned child's kernel PID. POSIX PIDs fit id_t;
            // no other child is selected, and the output pointer is live.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.child.id(),
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result != 0 {
                if io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD) {
                    self.owned = false; // External reaping: never signal a possibly reused PID.
                }
                return Err(Error::Io("Cannot inspect owned slicer child"));
            }
            #[cfg(target_os = "macos")]
            let pid = info.si_pid;
            // SAFETY: waitid filled this initialized siginfo_t; si_pid reads its
            // child-status member selected by WEXITED.
            #[cfg(target_os = "linux")]
            let pid = unsafe { info.si_pid() };
            Ok(pid != 0)
        }
        pub fn finish(&mut self) -> Result<ExitStatus> {
            if !self.owned {
                return Err(Error::Io("Slicer process ownership was lost"));
            }
            // SAFETY: the group was created by process_group(0); its leader is
            // still our unreaped child, so its PID/PGID cannot have been reused.
            let result = unsafe { libc::kill(-(self.child.id() as libc::pid_t), libc::SIGKILL) };
            if result != 0 && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                return Err(Error::Io("Cannot stop owned slicer group; outcome unknown"));
            }
            let result = self.child.wait();
            self.owned = false;
            result.map_err(|_| Error::Io("Cannot reap owned slicer child"))
        }
    }
    impl Drop for OwnedChild {
        fn drop(&mut self) {
            if self.owned && self.finish().is_err() {
                eprintln!("prusalink slicer: owned process cleanup failed; outcome unknown");
            }
        }
    }
}
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub use unix::OwnedChild;
