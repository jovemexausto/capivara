use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::mem::{size_of, zeroed};
use std::os::unix::fs::FileExt;
use std::os::unix::io::FromRawFd;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

#[cfg(target_os = "linux")]
use std::os::unix::io::AsRawFd;

struct Klog(Option<File>);

impl Klog {
    fn open() -> Self {
        let file = OpenOptions::new()
            .write(true)
            .open("/dev/kmsg")
            .or_else(|_| OpenOptions::new().write(true).open("/dev/console"))
            .ok();
        Self(file)
    }

    fn log(&mut self, msg: impl AsRef<str>) {
        let line = format!("<6>lpprobe: {}\n", msg.as_ref());
        if let Some(ref mut file) = self.0 {
            let _ = file.write_all(line.as_bytes());
        } else {
            let _ = std::io::stdout().write_all(line.as_bytes());
            let _ = std::io::stdout().flush();
        }
    }
}

#[cfg(target_os = "linux")]
fn mount_fs(src: &str, target: &str, fstype: &str) {
    let _ = fs::create_dir_all(target);
    let s = CString::new(src).unwrap();
    let t = CString::new(target).unwrap();
    let f = CString::new(fstype).unwrap();
    unsafe {
        let rc = libc::mount(s.as_ptr(), t.as_ptr(), f.as_ptr(), 0, std::ptr::null());
        if rc != 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EBUSY) {
                let _ = err;
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn mount_fs(_src: &str, target: &str, _fstype: &str) {
    let _ = fs::create_dir_all(target);
}

fn ensure_dir(path: &str) {
    let _ = fs::create_dir_all(path);
}

#[cfg(target_os = "linux")]
fn ensure_devnode(path: &str, dev_type: char, major: u64, minor: u64) {
    if Path::new(path).exists() {
        return;
    }
    let mode = match dev_type {
        'b' => libc::S_IFBLK,
        _ => libc::S_IFCHR,
    } | 0o600;
    let dev = libc::makedev(major as _, minor as _);
    let cpath = CString::new(path).unwrap();
    unsafe {
        let _ = libc::mknod(cpath.as_ptr(), mode, dev);
    }
}

#[cfg(not(target_os = "linux"))]
fn ensure_devnode(_path: &str, _dev_type: char, _major: u64, _minor: u64) {}

#[cfg(target_os = "linux")]
fn last_errno() -> i32 {
    unsafe { *libc::__errno_location() }
}

#[cfg(target_os = "macos")]
fn last_errno() -> i32 {
    unsafe { *libc::__error() }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn last_errno() -> i32 {
    38
}

fn errno_name(e: i32) -> &'static str {
    match e {
        0 => "OK",
        2 => "ENOENT",
        5 => "EIO",
        6 => "ENXIO",
        16 => "EBUSY",
        19 => "ENODEV",
        22 => "EINVAL",
        25 => "ENOTTY",
        _ => "?",
    }
}

#[cfg(target_os = "linux")]
fn finit_module(path: &str) -> i32 {
    let f = match File::open(path) {
        Ok(f) => f,
        Err(_) => return -1000,
    };
    let params = CString::new("").unwrap();
    let rc = unsafe { libc::syscall(libc::SYS_finit_module, f.as_raw_fd(), params.as_ptr(), 0) };
    if rc < 0 {
        -last_errno()
    } else {
        rc as i32
    }
}

#[cfg(not(target_os = "linux"))]
fn finit_module(_path: &str) -> i32 {
    -38
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DmIoctl {
    version: [u32; 3],
    data_size: u32,
    data_start: u32,
    target_count: u32,
    open_count: i32,
    flags: u32,
    event_nr: u32,
    padding: u32,
    dev: u64,
    name: [u8; 128],
    uuid: [u8; 129],
    data: [u8; 7],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DmTargetSpec {
    sector_start: u64,
    length: u64,
    status: i32,
    next: u32,
    target_type: [u8; 16],
}

const DM_IOCTL: u64 = 0xfd;

const fn iowr(nr: u64, size: usize) -> u64 {
    (3u64 << 30) | (DM_IOCTL << 8) | nr | ((size as u64) << 16)
}

const DM_DEV_CREATE: u64 = iowr(3, size_of::<DmIoctl>());
const DM_DEV_SUSPEND: u64 = iowr(6, size_of::<DmIoctl>());
const DM_DEV_STATUS: u64 = iowr(7, size_of::<DmIoctl>());
const DM_TABLE_LOAD: u64 = iowr(9, size_of::<DmIoctl>());

fn dm_simple(fd: i32, req: u64, name: &str) -> (i32, i32) {
    let mut dm: DmIoctl = unsafe { zeroed() };
    dm.version = [4, 0, 0];
    dm.data_size = size_of::<DmIoctl>() as u32;
    dm.data_start = 0;
    let nb = name.as_bytes();
    dm.name[..nb.len()].copy_from_slice(nb);
    let rc = unsafe { libc::ioctl(fd, req as _, &mut dm) };
    let errno = if rc < 0 { last_errno() } else { 0 };
    (rc, errno)
}

fn dm_table_load_linear(
    fd: i32,
    name: &str,
    len_sectors: u64,
    maj: u32,
    min: u32,
    offset: u64,
) -> (i32, i32) {
    let mut params = format!("{}:{} {}", maj, min, offset).into_bytes();
    params.push(0);
    while params.len() % 8 != 0 {
        params.push(0);
    }

    let header = size_of::<DmIoctl>();
    let spec_sz = size_of::<DmTargetSpec>();
    let total = header + spec_sz + params.len();
    let mut buf = vec![0u8; total];

    unsafe {
        let dm = &mut *(buf.as_mut_ptr() as *mut DmIoctl);
        dm.version = [4, 0, 0];
        dm.data_size = total as u32;
        dm.data_start = header as u32;
        dm.target_count = 1;
        let nb = name.as_bytes();
        dm.name[..nb.len()].copy_from_slice(nb);

        let spec = &mut *(buf.as_mut_ptr().add(header) as *mut DmTargetSpec);
        spec.sector_start = 0;
        spec.length = len_sectors;
        spec.next = (spec_sz + params.len()) as u32;
        spec.target_type[..6].copy_from_slice(b"linear");
    }
    buf[header + spec_sz..].copy_from_slice(&params);

    let rc = unsafe { libc::ioctl(fd, DM_TABLE_LOAD as _, buf.as_mut_ptr()) };
    let errno = if rc < 0 { last_errno() } else { 0 };
    (rc, errno)
}

fn dm_probe(
    fd: i32,
    name: &str,
    start: u64,
    len: u64,
    super_major: u32,
    super_minor: u32,
    log: &mut Klog,
) {
    log.log(format!("{name:14} enter dm_probe"));
    let (rc, e) = dm_simple(fd, DM_DEV_CREATE, name);
    log.log(format!(
        "{name:14} CREATE rc={rc:4} errno={}({})",
        e,
        errno_name(e)
    ));

    log.log(format!("{name:14} STEP LOAD start"));
    let (rc, e) = dm_table_load_linear(fd, name, len, super_major, super_minor, start);
    log.log(format!(
        "{name:14} LOAD   rc={rc:4} errno={}({})",
        e,
        errno_name(e)
    ));

    log.log(format!("{name:14} STEP RESUME start"));
    let (rc, e) = dm_simple(fd, DM_DEV_SUSPEND, name);
    log.log(format!(
        "{name:14} RESUME rc={rc:4} errno={}({})",
        e,
        errno_name(e)
    ));

    log.log(format!("{name:14} STEP STATUS start"));
    let (rc, e) = dm_simple(fd, DM_DEV_STATUS, name);
    log.log(format!(
        "{name:14} STATUS rc={rc:4} errno={}({})",
        e,
        errno_name(e)
    ));
}

fn direct_read(fd: &File, name: &str, offset_sectors: u64, log: &mut Klog) {
    let mut buf = [0u8; 512];
    let off = offset_sectors * 512;
    log.log(format!("{name:14} READ start off={off}"));
    match fd.read_at(&mut buf, off) {
        Ok(n) => {
            let head = buf[..n.min(16)]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            log.log(format!("{name:14} READ rc={n} head={head}"));
        }
        Err(e) => {
            log.log(format!("{name:14} READ err={e}"));
        }
    }
}

fn find_module_path(rel: &str) -> Option<PathBuf> {
    let root = Path::new("/lib/modules");
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = fs::read_dir(&dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            if path.ends_with(rel) {
                return Some(path);
            }
        }
    }
    None
}

fn find_super_partition() -> Option<(u32, u32)> {
    for entry in fs::read_dir("/sys/class/block").ok()?.flatten() {
        let name = entry.file_name().into_string().ok()?;
        if !name.starts_with("vda") || name == "vda" {
            continue;
        }
        let start = fs::read_to_string(format!("/sys/class/block/{name}/start")).ok()?;
        if start.trim() == "198656" {
            let dev = fs::read_to_string(format!("/sys/class/block/{name}/dev")).ok()?;
            let (maj, min) = dev.trim().split_once(':')?;
            return Some((maj.parse().ok()?, min.parse().ok()?));
        }
    }
    None
}

fn read_trimmed(path: &str) -> Option<String> {
    let mut s = String::new();
    File::open(path).ok()?.read_to_string(&mut s).ok()?;
    Some(s.trim().to_string())
}

fn dump_state(log: &mut Klog) {
    if let Ok(p) = fs::read_to_string("/proc/cmdline") {
        log.log(format!("cmdline: {}", p.trim()));
    }
    if let Ok(p) = fs::read_to_string("/proc/partitions") {
        let mut count = 0;
        let mut has_vda = false;
        for line in p.lines().skip(2) {
            let name = line.split_whitespace().last().unwrap_or("");
            if !name.is_empty() {
                count += 1;
                if name == "vda" {
                    has_vda = true;
                }
            }
        }
        log.log(format!("partitions: count={count} vda_present={has_vda}"));
    }
}

fn wait_and_exit(log: &mut Klog, msg: &str) {
    log.log(msg);
    sleep(Duration::from_secs(130));
}

fn main() {
    ensure_dir("/proc");
    ensure_dir("/sys");
    ensure_dir("/dev");
    ensure_dir("/dev/mapper");
    mount_fs("proc", "/proc", "proc");
    mount_fs("sysfs", "/sys", "sysfs");
    mount_fs("devtmpfs", "/dev", "devtmpfs");
    ensure_devnode("/dev/console", 'c', 5, 1);
    ensure_devnode("/dev/kmsg", 'c', 1, 11);

    ensure_devnode("/dev/device-mapper", 'c', 10, 236);
    ensure_devnode("/dev/mapper/control", 'c', 10, 236);

    let mut log = Klog::open();
    log.log("=== lpprobe start ===");

    if let Some(path) = find_module_path("kernel/drivers/block/virtio_blk.ko") {
        let path_str = path.to_string_lossy().into_owned();
        let rc = finit_module(&path_str);
        log.log(format!(
            "finit_module virtio_blk -> {rc} ({})",
            errno_name((-rc).max(0))
        ));
    } else {
        if let Ok(entries) = fs::read_dir("/lib/modules") {
            for entry in entries.flatten() {
                log.log(format!("modules root entry: {}", entry.path().display()));
            }
        }
        log.log("virtio_blk.ko not found under /lib/modules");
    }

    sleep(Duration::from_millis(300));
    dump_state(&mut log);

    let Some((super_major, super_minor)) = find_super_partition() else {
        wait_and_exit(
            &mut log,
            "super partition NOT FOUND in sysfs (start==198656)",
        );
        return;
    };
    log.log(format!("super device = {super_major}:{super_minor}"));

    let super_node = CString::new("/dev/lpprobe-super").unwrap();
    ensure_devnode(
        "/dev/lpprobe-super",
        'b',
        super_major as u64,
        super_minor as u64,
    );
    let super_fd = unsafe { libc::open(super_node.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
    if super_fd < 0 {
        wait_and_exit(&mut log, "open /dev/lpprobe-super FAILED");
        return;
    }
    let super_file = unsafe { File::from_raw_fd(super_fd) };
    direct_read(&super_file, "product_a", 2_048, &mut log);
    direct_read(&super_file, "system_a", 423_936, &mut log);

    let ctrl_candidates = ["/dev/mapper/control", "/dev/device-mapper"];
    let mut ctrl_fd = -1;
    for c in ctrl_candidates {
        let cpath = CString::new(c).unwrap();
        ctrl_fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        if ctrl_fd >= 0 {
            log.log(format!("opened device-mapper control: {c}"));
            break;
        }
    }
    if ctrl_fd < 0 {
        wait_and_exit(&mut log, "open device-mapper control FAILED");
        return;
    }

    const PARTS: &[(&str, u64, u64)] = &[
        ("product_a", 2_048, 421_120),
        ("system_ext_a", 1_878_016, 486_808),
        ("vendor_a", 2_385_920, 588_616),
        ("system_a", 423_936, 1_442_720),
    ];

    log.log("lpprobe: entering dm loop");
    for (name, start, len) in PARTS {
        dm_probe(
            ctrl_fd,
            name,
            *start,
            *len,
            super_major,
            super_minor,
            &mut log,
        );
    }

    wait_and_exit(
        &mut log,
        "=== lpprobe done; exiting after hung-task window ===",
    );
}
