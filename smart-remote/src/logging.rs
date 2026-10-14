//! Only audited plugin diagnostics reach stderr; dependency payload logs cannot be enabled.
use log::{Log, Metadata, Record};

struct SafeLogger<L>(L);
fn allowed(metadata: &Metadata<'_>) -> bool {
    let target = metadata.target();
    target == "smart_remote_plugin" || target.starts_with("smart_remote_plugin::")
}
impl<L: Log> Log for SafeLogger<L> {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        allowed(metadata) && self.0.enabled(metadata)
    }
    fn log(&self, record: &Record<'_>) {
        if self.enabled(record.metadata()) {
            self.0.log(record);
        }
    }
    fn flush(&self) {
        self.0.flush();
    }
}
pub fn init() -> Result<(), log::SetLoggerError> {
    let logger =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .target(env_logger::Target::Stderr)
            .build();
    let max = logger.filter();
    log::set_boxed_logger(Box::new(SafeLogger(logger)))?;
    log::set_max_level(max);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use log::Level;
    use std::sync::{Arc, Mutex};
    struct Captured(Arc<Mutex<Vec<String>>>);
    impl std::io::Write for Captured {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .unwrap()
                .push(String::from_utf8_lossy(bytes).into_owned());
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    #[test]
    fn global_and_descendant_trace_directives_cannot_emit_dependency_wire_frames() {
        for filter in ["trace", "trace,btleplug::corebluetooth::central_delegate=trace,dbus::channel=trace,bluez_async::session=trace,tokio::io::stdio=trace"] {
            let captured = Arc::new(Mutex::new(Vec::new()));
            // parse_filters is the same parser used for the RUST_LOG value;
            // avoid changing process-global environment during parallel tests.
            let mut builder = env_logger::Builder::new();
            builder.parse_filters(filter).target(env_logger::Target::Pipe(Box::new(Captured(captured.clone()))));
            let logger = SafeLogger(builder.build());
            for target in ["btleplug", "btleplug::corebluetooth::central_delegate", "btleplug::winrtble::ble::characteristic",
                "dbus", "dbus::channel", "bluez_async::session", "bluez_generated::gatt", "D-Bus", "tokio::io::stdio"] {
                for level in [Level::Trace, Level::Debug, Level::Info, Level::Warn, Level::Error] {
                    let metadata = Metadata::builder().target(target).level(level).build();
                    assert!(!logger.enabled(&metadata), "{target} {level}");
                    // Direct log() calls must be guarded as well as enabled().
                    logger.log(&Record::builder().metadata(metadata).args(format_args!("synthetic-wire-[1, 2, 3, 4]")).build());
                }
            }
            logger.log(&Record::builder().target("smart_remote_plugin::host").level(Level::Trace).args(format_args!("own-diagnostic")).build());
            logger.log(&Record::builder().target("dbus::channel").level(Level::Warn).args(format_args!("safe-warning")).build());
            let output = captured.lock().unwrap().join("");
            assert!(!output.contains("synthetic-wire"));
            assert!(output.contains("own-diagnostic"));
            assert!(!output.contains("safe-warning"));
        }
    }
}
