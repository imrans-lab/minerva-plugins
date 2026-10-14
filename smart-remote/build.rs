// The protocol schemas are embedded with include_dir!, which does not make
// Cargo notice added or removed files; rerunning on the directory does.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        pkg_config::Config::new()
            .atleast_version("1.6")
            .probe("dbus-1")
            .map_err(|_| "Linux build requires libdbus-1-dev and pkg-config (dbus-1 >= 1.6)")?;
    }
    println!("cargo:rerun-if-changed=protocol/schema");
    println!("cargo:rerun-if-changed=proto/espressif");
    let descriptors = protox::compile(
        [
            "proto/espressif/session.proto",
            "proto/espressif/wifi_config.proto",
            "proto/espressif/wifi_scan.proto",
            "proto/espressif/wifi_ctrl.proto",
        ],
        ["proto/espressif"],
    )
    .map_err(|error| format!("cannot parse provisioning schemas: {error}"))?;
    prost_build::Config::new()
        .skip_debug(["."])
        .compile_fds(descriptors)
        .map_err(|error| format!("cannot generate provisioning messages: {error}"))?;
    Ok(())
}
