use std::{env, fs, path::PathBuf};

static VERSION: &str = "1.0.30";

fn link(name: &str, bundled: bool) {
    use std::env::var;
    let target = var("TARGET").unwrap();
    let target: Vec<_> = target.split('-').collect();
    if target.get(2) == Some(&"windows") {
        println!("cargo:rustc-link-lib=dylib={}", name);
        if bundled && target.get(3) == Some(&"gnu") {
            let dir = var("CARGO_MANIFEST_DIR").unwrap();
            println!("cargo:rustc-link-search=native={}/{}", dir, target[0]);
        }
    }
}

pub fn link_framework(name: &str) {
    println!("cargo:rustc-link-lib=framework={}", name);
}

fn get_macos_major_version() -> Option<usize> {
    if !cfg!(target_os = "macos") {
        return None;
    }

    let output = std::process::Command::new("sw_vers")
        .args(["-productVersion"])
        .output()
        .unwrap();
    let version = std::str::from_utf8(&output.stdout).unwrap().trim_end();
    let components: Vec<&str> = version.split('.').collect();
    let major: usize = components[0].parse().unwrap();
    Some(major)
}

fn find_libusb_pkg(statik: bool) -> bool {
    if std::env::var("CARGO_CFG_TARGET_ENV") == Ok("msvc".into()) {
        #[cfg(target_os = "windows")]
        return match vcpkg::Config::new().find_package("libusb") {
            Ok(_) => true,
            Err(e) => {
                if pkg_config::probe_library("libusb-1.0").is_ok() {
                    true
                } else {
                    println!("Can't find libusb pkg: {:?}", e);
                    false
                }
            }
        };
    }
    // https://github.com/rust-lang/rust/issues/96943
    let needs_rustc_issue_96943_workaround: bool = get_macos_major_version()
        .map(|major| major >= 11)
        .unwrap_or_default();

    match pkg_config::Config::new().statik(statik).probe("libusb-1.0") {
        Ok(l) => {
            for lib in l.libs {
                if statik {
                    if needs_rustc_issue_96943_workaround && lib == "objc" {
                        continue;
                    }
                    println!("cargo:rustc-link-lib=static={}", lib);
                }
            }
            // Provide metadata and include directory for dependencies
            if statik {
                println!("cargo:static=1");
            }
            assert!(l.include_paths.len() <= 1); // Cannot have multiple env vars with same name
            for path in l.include_paths {
                println!("cargo:include={}", path.to_str().unwrap());
            }
            println!("cargo:version_number={}", l.version);
            true
        }
        Err(e) => {
            println!("Can't find libusb pkg: {:?}", e);
            false
        }
    }
}

fn make_source() {
    let libusb_source = PathBuf::from("libusb");

    /*
    Example environment variables and values:

    CARGO_CFG_TARGET_ARCH: aarch64
    CARGO_CFG_TARGET_ENDIAN: little
    CARGO_CFG_TARGET_ENV:
    CARGO_CFG_TARGET_FAMILY: unix
    CARGO_CFG_TARGET_OS: android
    CARGO_CFG_TARGET_POINTER_WIDTH: 64
    CARGO_CFG_TARGET_VENDOR: unknown
    CARGO_CFG_UNIX:
    */

    // Provide metadata and include directory for dependencies
    println!("cargo:vendored=1");
    println!("cargo:static=1");
    let include_dir = PathBuf::from(env::var("OUT_DIR").unwrap()).join("include");
    fs::create_dir_all(&include_dir).unwrap();
    fs::copy(
        libusb_source.join("libusb/libusb.h"),
        include_dir.join("libusb.h"),
    )
    .unwrap();
    println!("cargo:include={}", include_dir.to_str().unwrap());

    fs::File::create(format!("{}/{}", include_dir.display(), "config.h")).unwrap();
    let mut base_config = cc::Build::new();
    base_config.include(&include_dir);
    base_config.include(libusb_source.join("libusb"));

    base_config.define("PRINTF_FORMAT(a, b)", Some(""));
    base_config.define("ENABLE_LOGGING", Some("1"));

    if std::env::var("CARGO_CFG_TARGET_ENV") == Ok("msvc".into()) {
        fs::copy(
            libusb_source.join("msvc/config.h"),
            include_dir.join("config.h"),
        )
        .unwrap();
    }

    if std::env::var("CARGO_CFG_TARGET_OS") == Ok("macos".into()) {
        base_config.define("OS_DARWIN", Some("1"));
        base_config.define("TARGET_OS_OSX", Some("1"));
        base_config.file(libusb_source.join("libusb/os/darwin_usb.c"));
        link_framework("CoreFoundation");
        link_framework("IOKit");
        link_framework("Security");
        link("objc", false);
    }

    if std::env::var("CARGO_CFG_TARGET_OS") == Ok("linux".into())
        || std::env::var("CARGO_CFG_TARGET_OS") == Ok("android".into())
    {
        base_config.define("OS_LINUX", Some("1"));
        base_config.define("HAVE_ASM_TYPES_H", Some("1"));
        base_config.define("_GNU_SOURCE", Some("1"));
        base_config.define("HAVE_TIMERFD", Some("1"));
        base_config.define("HAVE_EVENTFD", Some("1"));
        base_config.file(libusb_source.join("libusb/os/linux_netlink.c"));
        base_config.file(libusb_source.join("libusb/os/linux_usbfs.c"));
    }

    if std::env::var("CARGO_CFG_TARGET_FAMILY") == Ok("unix".into()) {
        base_config.define("HAVE_SYS_TIME_H", Some("1"));
        base_config.define("HAVE_NFDS_T", Some("1"));
        base_config.define("PLATFORM_POSIX", Some("1"));
        base_config.define("HAVE_CLOCK_GETTIME", Some("1"));
        base_config.define(
            "DEFAULT_VISIBILITY",
            Some("__attribute__((visibility(\"hidden\")))"),
        );

        if let Ok(lib) = pkg_config::probe_library("libudev") {
            base_config.define("USE_UDEV", Some("1"));
            base_config.define("HAVE_LIBUDEV", Some("1"));
            base_config.file(libusb_source.join("libusb/os/linux_udev.c"));
            for path in lib.include_paths {
                base_config.include(path.to_str().unwrap());
            }
        };

        println!("Including posix!");
        base_config.file(libusb_source.join("libusb/os/events_posix.c"));
        base_config.file(libusb_source.join("libusb/os/threads_posix.c"));
    }

    if std::env::var("CARGO_CFG_TARGET_OS") == Ok("windows".into()) {
        if std::env::var("CARGO_CFG_TARGET_ENV") == Ok("msvc".into()) {
            base_config.flag("/source-charset:utf-8");
        }

        base_config.warnings(false);
        base_config.define("OS_WINDOWS", Some("1"));
        base_config.file(libusb_source.join("libusb/os/events_windows.c"));
        base_config.file(libusb_source.join("libusb/os/threads_windows.c"));
        base_config.file(libusb_source.join("libusb/os/windows_common.c"));
        base_config.file(libusb_source.join("libusb/os/windows_usbdk.c"));
        base_config.file(libusb_source.join("libusb/os/windows_winusb.c"));

        base_config.define("DEFAULT_VISIBILITY", Some(""));
        base_config.define("PLATFORM_WINDOWS", Some("1"));
        link("user32", false);
    }

    base_config.file(libusb_source.join("libusb/core.c"));
    base_config.file(libusb_source.join("libusb/descriptor.c"));
    base_config.file(libusb_source.join("libusb/hotplug.c"));
    base_config.file(libusb_source.join("libusb/io.c"));
    base_config.file(libusb_source.join("libusb/strerror.c"));
    base_config.file(libusb_source.join("libusb/sync.c"));

    base_config.compile("usb-vendored");
    println!("cargo:version_number={}", VERSION);
}

fn main() {
    println!("cargo:rerun-if-env-changed=LIBUSB_STATIC");
    let statik = {
        if cfg!(target_os = "macos") {
            match std::env::var("LIBUSB_STATIC").unwrap_or_default().as_ref() {
                "" | "0" => false,
                _ => true,
            }
        } else {
            std::env::var("CARGO_CFG_TARGET_FEATURE")
                .map(|s| s.contains("crt-static"))
                .unwrap_or_default()
        }
    };

    let is_freebsd = std::env::var("CARGO_CFG_TARGET_OS") == Ok("freebsd".into());

    if (!is_freebsd && cfg!(feature = "vendored")) || !find_libusb_pkg(statik) {
        make_source();
    }
}
