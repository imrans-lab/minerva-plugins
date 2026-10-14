// The protocol schemas are embedded with include_dir!, which does not make
// Cargo notice added or removed files; rerunning on the directory does.
fn main() -> Result<(), Box<dyn std::error::Error>> {
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
