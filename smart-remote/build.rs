// The protocol schemas are embedded with include_dir!, which does not make
// Cargo notice added or removed files; rerunning on the directory does.
fn main() {
    println!("cargo:rerun-if-changed=../protocol/schema");
}
