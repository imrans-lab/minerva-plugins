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
        #[cfg(target_os = "macos")]
        fn zombie_only_group(&self) -> Result<bool> {
            let output = Command::new("/bin/ps")
                .args(["-axo", "pid=,pgid=,stat="])
                .output()
                .map_err(|_| Error::Io("Cannot inspect exited slicer group"))?;
            if !output.status.success() {
                return Err(Error::Io("Cannot inspect exited slicer group"));
            }
            let text = std::str::from_utf8(&output.stdout)
                .map_err(|_| Error::Io("Invalid slicer group monitor output"))?;
            let mut leader = false;
            for line in text.lines() {
                let fields: Vec<_> = line.split_whitespace().collect();
                if fields.len() != 3 {
                    return Err(Error::Io("Incomplete slicer group monitor output"));
                }
                let pid = fields[0]
                    .parse::<u32>()
                    .map_err(|_| Error::Io("Invalid slicer PID"))?;
                let group = fields[1]
                    .parse::<u32>()
                    .map_err(|_| Error::Io("Invalid slicer group ID"))?;
                if group != self.id() {
                    continue;
                }
                if !fields[2].starts_with('Z') {
                    return Ok(false);
                }
                leader |= pid == self.id();
            }
            Ok(leader)
        }
        pub fn finish(&mut self) -> Result<ExitStatus> {
            if !self.owned {
                return Err(Error::Io("Slicer process ownership was lost"));
            }
            // SAFETY: the group was created by process_group(0); its leader is
            // still our unreaped child, so its PID/PGID cannot have been reused.
            let result = unsafe { libc::kill(-(self.child.id() as libc::pid_t), libc::SIGKILL) };
            if result != 0 {
                let errno = io::Error::last_os_error().raw_os_error();
                // Darwin excludes zombies from its group signal iteration and
                // returns EPERM when no live members remain (XNU killpg1).
                // Accept that case only while WNOWAIT still retains our exited
                // leader, and ps confirms every group member is a zombie.
                #[cfg(target_os = "macos")]
                let zombie_only =
                    errno == Some(libc::EPERM) && self.exited()? && self.zombie_only_group()?;
                #[cfg(not(target_os = "macos"))]
                let zombie_only = false;
                if errno != Some(libc::ESRCH) && !zombie_only {
                    return Err(Error::Io("Cannot stop owned slicer group; outcome unknown"));
                }
            }
            let result = self.child.wait();
            self.owned = false;
            result.map_err(|_| Error::Io("Cannot reap owned slicer child"))
        }
    }
    impl Drop for OwnedChild {
        fn drop(&mut self) {
            if self.owned && self.finish().is_err() {
                eprintln!("printer3d slicer: owned process cleanup failed; outcome unknown");
            }
        }
    }
}
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub use unix::OwnedChild;
