// build.rs do capy
//
// libkrun e suas dependências são resolvidas pelo workspace Cargo.
// O único link manual necessário é gfxstream_backend (C++ lib não-Cargo).
//
// GFXSTREAM_PATH deve apontar para vendor/gfxstream/build-macos/host
// (produzido pelo scripts/build-gfxstream.sh).

use std::env;

fn main() {
    // gfxstream_backend — biblioteca C++ compilada por meson (não é crate Cargo)
    let gfxstream_path = env::var("GFXSTREAM_PATH").unwrap_or_else(|_| {
        // Default: vendor/gfxstream/build-macos/host relativo ao root do workspace
        let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
        format!("{manifest}/../../vendor/gfxstream/build-macos/host")
    });

    // libkrun.dylib — produzida pelo workspace Cargo (SP-2a)
    let out_dir = env::var("OUT_DIR").unwrap();
    // OUT_DIR é target/debug/build/capy-*/out — subir 3 níveis para target/debug
    let target_dir = std::path::Path::new(&out_dir)
        .ancestors()
        .nth(3)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    println!("cargo:rustc-link-search=native={target_dir}");
    println!("cargo:rustc-link-lib=dylib=krun");

    println!("cargo:rustc-link-search=native={gfxstream_path}");
    println!("cargo:rustc-link-lib=dylib=gfxstream_backend");
    println!("cargo:rustc-link-lib=dylib=c++");

    // Apple frameworks requeridos por libgfxstream_backend.dylib
    for fw in &[
        "Hypervisor",
        "CoreFoundation",
        "IOKit",
        "AppKit",
        "Foundation",
        "Metal",
        "QuartzCore",
    ] {
        println!("cargo:rustc-link-lib=framework={fw}");
    }

    println!("cargo:rerun-if-env-changed=GFXSTREAM_PATH");
}
