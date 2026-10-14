// The protocol schemas are embedded with include_dir!, which does not make
// Cargo notice added or removed files; rerunning on the directory does.
fn main() {
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
    .expect("canonical provisioning schemas must parse");
    prost_build::Config::new()
        .skip_debug(["."])
        .compile_fds(descriptors)
        .expect("canonical provisioning messages must generate");
}
