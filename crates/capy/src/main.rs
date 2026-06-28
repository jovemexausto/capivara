//! capy — Capivara VM launcher
//!
//! Dois modos de boot:
//!
//! Modo kernel externo (--kernel):
//!   Passa um kernel arm64 + initramfs externo. Requer KRUN_KERNEL_FORMAT_IMAGE.
//!
//! Modo libkrunfw (--root + --exec):  ← MODO CORRETO para SP-3+
//!   Usa o kernel embutido no libkrunfw.dylib. Root via virtiofs.
//!   Executa um processo específico no guest.

#![allow(non_camel_case_types)]
#![allow(non_snake_case)]
#![allow(dead_code)]

use std::ffi::{c_void, CString};
use std::io;
use std::io::Write;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::raw::{c_char, c_int};
use std::os::unix::net::UnixStream;
use std::ptr::null;
use std::thread;

use anyhow::{bail, Context};
use clap::Parser;
use log::{error, info, warn};

mod soc;
use soc::{BootContract, DiskRole, KernelImage, SocModel};

// ─── libkrun C bindings ──────────────────────────────────────────────────────

type int32_t = i32;
type uint32_t = u32;
type uint64_t = u64;
type uint8_t = u8;
type size_t = libc::size_t;

const KRUN_KERNEL_FORMAT_IMAGE: u32 = 0;
const KRUN_LOG_TARGET_DEFAULT: i32 = -1;
const KRUN_LOG_LEVEL_WARN: u32 = 2;
const KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER: u64 = 1;

#[repr(C)]
struct krun_rect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

type krun_display_create_fn =
    Option<unsafe extern "C" fn(*mut *mut c_void, *const c_void, *const c_void) -> i32>;
type krun_display_destroy_fn = Option<unsafe extern "C" fn(*mut c_void) -> i32>;
// 7 params: instance, scanout_id, display_width, display_height, width, height, format
type krun_display_configure_scanout_fn =
    Option<unsafe extern "C" fn(*mut c_void, u32, u32, u32, u32, u32, u32) -> i32>;
type krun_display_disable_scanout_fn = Option<unsafe extern "C" fn(*mut c_void, u32) -> i32>;
type krun_display_alloc_frame_fn =
    Option<unsafe extern "C" fn(*mut c_void, u32, *mut *mut u8, *mut size_t) -> i32>;
type krun_display_present_frame_fn =
    Option<unsafe extern "C" fn(*mut c_void, u32, u32, *const krun_rect) -> i32>;

#[repr(C)]
struct krun_display_basic_framebuffer_vtable {
    destroy: krun_display_destroy_fn,
    disable_scanout: krun_display_disable_scanout_fn,
    configure_scanout: krun_display_configure_scanout_fn,
    alloc_frame: krun_display_alloc_frame_fn,
    present_frame: krun_display_present_frame_fn,
}

#[repr(C)]
union krun_display_vtable {
    basic_framebuffer: std::mem::ManuallyDrop<krun_display_basic_framebuffer_vtable>,
}

#[repr(C)]
struct krun_display_backend {
    features: u64,
    create_userdata: *const c_void,
    create: krun_display_create_fn,
    vtable: krun_display_vtable,
}
unsafe impl Send for krun_display_backend {}

type krun_set_root_disk_fn = unsafe extern "C" fn(u32, *const c_char) -> i32;
type krun_add_disk_fn = unsafe extern "C" fn(u32, *const c_char, *const c_char, bool) -> i32;
const VIRGLRENDERER_USE_EXTERNAL_BLOB: u32 = 1 << 5;

extern "C" {
    fn krun_init_log(fd: c_int, level: u32, style: u32, reserved: u32) -> i32;
    fn krun_create_ctx() -> i32;
    fn krun_set_vm_config(ctx_id: u32, num_vcpus: u8, ram_mib: u32) -> i32;
    fn krun_set_gpu_options2(ctx_id: u32, virgl_flags: u32, shm_size: u64) -> i32;
    fn krun_add_display(ctx_id: u32, width: u32, height: u32) -> i32;
    fn krun_set_display_backend(ctx_id: u32, backend: *const c_void, sz: size_t) -> i32;
    fn krun_set_kernel(
        ctx_id: u32,
        path: *const c_char,
        fmt: u32,
        initrd: *const c_char,
        cmdline: *const c_char,
    ) -> i32;
    fn krun_set_console_output(ctx_id: u32, c_filepath: *const c_char) -> i32;
    fn krun_set_kernel_console(ctx_id: u32, console_id: *const c_char) -> i32;
    fn krun_add_serial_console_default(ctx_id: u32, input_fd: c_int, output_fd: c_int) -> i32;
    fn krun_set_root(ctx_id: u32, root_path: *const c_char) -> i32;
    fn krun_set_tpm_socket(ctx_id: u32, path: *const c_char) -> i32;
    fn krun_set_exec(
        ctx_id: u32,
        exec_path: *const c_char,
        argv: *const *const c_char,
        envp: *const *const c_char,
    ) -> i32;
    fn krun_add_vsock_port(ctx_id: u32, port: u32, c_filepath: *const c_char) -> i32;
    fn krun_add_vsock_port2(ctx_id: u32, port: u32, c_filepath: *const c_char, listen: bool)
        -> i32;
    fn krun_start_enter(ctx_id: u32) -> i32;
}

fn get_krun_set_root_disk() -> Option<krun_set_root_disk_fn> {
    let symbol = CString::new("krun_set_root_disk").unwrap();
    let ptr = unsafe { libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr()) };
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::mem::transmute(ptr) })
    }
}

fn get_krun_add_disk() -> Option<krun_add_disk_fn> {
    let symbol = CString::new("krun_add_disk").unwrap();
    let ptr = unsafe { libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr()) };
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::mem::transmute(ptr) })
    }
}

fn setup_serial_capture(path: &str) -> anyhow::Result<(c_int, c_int)> {
    let mut master: c_int = -1;
    let mut slave: c_int = -1;
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error().into());
    }

    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)?;
    let master_fd = master;
    thread::spawn(move || {
        let mut file = file;
        let mut stdout = std::io::stdout();
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe { libc::read(master_fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            let _ = std::io::Write::write_all(&mut file, &buf[..n as usize]);
            let _ = stdout.write_all(&buf[..n as usize]);
            let _ = stdout.flush();
        }
        unsafe { libc::close(master_fd) };
    });

    Ok((slave, slave))
}

fn start_adb_bridge(unix_path: &'static str, tcp_addr: &'static str) -> anyhow::Result<()> {
    let listener =
        TcpListener::bind(tcp_addr).with_context(|| format!("bridge bind {tcp_addr}"))?;

    thread::spawn(move || {
        for stream in listener.incoming() {
            let tcp = match stream {
                Ok(stream) => stream,
                Err(err) => {
                    warn!("adb bridge accept failed: {err}");
                    continue;
                }
            };

            let unix = match UnixStream::connect(unix_path) {
                Ok(stream) => stream,
                Err(err) => {
                    warn!("adb bridge connect to {unix_path} failed: {err}");
                    let _ = tcp.shutdown(Shutdown::Both);
                    continue;
                }
            };

            thread::spawn(move || proxy_adb_connection(tcp, unix));
        }
    });

    Ok(())
}

fn proxy_adb_connection(tcp: TcpStream, unix: UnixStream) {
    let mut tcp_rx = tcp;
    let mut tcp_tx = match tcp_rx.try_clone() {
        Ok(stream) => stream,
        Err(err) => {
            warn!("adb bridge tcp clone failed: {err}");
            return;
        }
    };

    let mut unix_rx = unix;
    let mut unix_tx = match unix_rx.try_clone() {
        Ok(stream) => stream,
        Err(err) => {
            warn!("adb bridge unix clone failed: {err}");
            return;
        }
    };

    let tcp_to_unix = thread::spawn(move || io::copy(&mut tcp_rx, &mut unix_tx));
    let unix_to_tcp = thread::spawn(move || io::copy(&mut unix_rx, &mut tcp_tx));

    if let Err(err) = tcp_to_unix.join() {
        warn!("adb bridge tcp->unix thread panicked: {err:?}");
    }
    if let Err(err) = unix_to_tcp.join() {
        warn!("adb bridge unix->tcp thread panicked: {err:?}");
    }
}

// ─── Headless display backend ─────────────────────────────────────────────────

const HEADLESS_FRAME_BUF_SIZE: usize = 3840 * 2160 * 4;

struct HeadlessDisplay {
    frame_buf: Vec<u8>,
}
impl HeadlessDisplay {
    fn new() -> Self {
        Self {
            frame_buf: vec![0u8; HEADLESS_FRAME_BUF_SIZE],
        }
    }
}

// create: copia create_userdata → *instance (sem isso: segfault com instance=null)
unsafe extern "C" fn headless_create(
    instance: *mut *mut c_void,
    userdata: *const c_void,
    _: *const c_void,
) -> i32 {
    *instance = userdata as *mut c_void;
    0
}
unsafe extern "C" fn headless_disable_scanout(_: *mut c_void, id: u32) -> i32 {
    info!("display: disable scanout {id}");
    0
}
unsafe extern "C" fn headless_configure_scanout(
    _: *mut c_void,
    id: u32,
    _dw: u32,
    _dh: u32,
    w: u32,
    h: u32,
    _fmt: u32,
) -> i32 {
    info!("display: configure scanout {id} {w}x{h}");
    0
}
unsafe extern "C" fn headless_alloc_frame(
    instance: *mut c_void,
    _: u32,
    buffer: *mut *mut u8,
    sz: *mut size_t,
) -> i32 {
    let disp = &mut *(instance as *mut HeadlessDisplay);
    *buffer = disp.frame_buf.as_mut_ptr();
    *sz = disp.frame_buf.len();
    0
}
unsafe extern "C" fn headless_present_frame(
    _: *mut c_void,
    _: u32,
    _: u32,
    _: *const krun_rect,
) -> i32 {
    0 // descarta — SP-4 vai aqui fazer encode para scrcpy
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(name = "capy", about = "Capivara — Android VM for macOS ARM64")]
struct Args {
    // ── Modo libkrunfw (recomendado) ──
    /// Diretório raiz do guest (virtiofs). Usa kernel embutido no libkrunfw.
    #[arg(long)]
    root: Option<String>,

    /// Disco raiz do guest (virtio-blk). Usa o init embutido do libkrun.
    #[arg(long)]
    root_disk: Option<String>,

    /// Disco adicional do guest (virtio-blk). Pode ser repetido.
    #[arg(long)]
    disk: Vec<String>,

    /// Socket unix do swtpm no host.
    #[arg(long)]
    tpm_socket: Option<String>,

    /// Executável a rodar no guest (relativo ao --root)
    #[arg(long)]
    exec: Option<String>,

    /// Argumentos para o executável do guest
    #[arg(long)]
    exec_args: Vec<String>,

    // ── Modo kernel externo (debug) ──
    /// Kernel arm64 externo (Image). Alternativa ao modo libkrunfw.
    #[arg(long)]
    kernel: Option<String>,

    /// Initramfs para o kernel externo
    #[arg(long)]
    initramfs: Option<String>,

    /// Kernel cmdline (modo kernel externo)
    #[arg(
        long,
        default_value = "console=ttyS0 loglevel=8 androidboot.init_fatal_reboot_target=bootloader androidboot.selinux=permissive selinux=permissive"
    )]
    cmdline: String,

    /// Permite continuar mesmo com um mismatch conhecido entre o transport do VMM e o guest.
    #[arg(long)]
    allow_transport_mismatch: bool,

    // ── Configuração comum ──
    #[arg(long, default_value_t = 4)]
    vcpus: u8,

    #[arg(long, default_value_t = 4096)]
    ram_mib: u32,

    #[arg(long, default_value_t = 1080)]
    width: u32,

    #[arg(long, default_value_t = 1920)]
    height: u32,

    /// Não configura display/gfxstream. Útil para bring-up do boot sem UI.
    #[arg(long)]
    no_display: bool,

    #[arg(short, long)]
    verbose: bool,
}

// ─── Boot ─────────────────────────────────────────────────────────────────────

macro_rules! krun_check {
    ($expr:expr) => {{
        let ret = unsafe { $expr };
        if ret < 0 {
            bail!("{} failed: {}", stringify!($expr), ret);
        }
        ret
    }};
}
macro_rules! krun_check_u32 {
    ($expr:expr) => {{
        let ret = unsafe { $expr };
        if ret < 0 {
            bail!("{} failed: {}", stringify!($expr), ret);
        }
        ret as u32
    }};
}

fn boot(args: &Args) -> anyhow::Result<()> {
    let contract = build_boot_contract(args)?;
    validate_transport(args, &contract)?;

    krun_check!(krun_init_log(
        KRUN_LOG_TARGET_DEFAULT,
        if args.verbose { 0 } else { KRUN_LOG_LEVEL_WARN },
        0,
        0
    ));

    let ctx = krun_check_u32!(krun_create_ctx());
    info!("VM context: {ctx}");

    krun_check!(krun_set_vm_config(ctx, args.vcpus, args.ram_mib));
    info!("VM: {} vCPUs, {} MiB RAM", args.vcpus, args.ram_mib);

    // GPU
    // Tentativa de habilitar VIRGLRENDERER_USE_EGL|USE_GLES testada em
    // 2026-06-19 para destravar o crash-loop do surfaceflinger
    // ("no suitable EGLConfig found, giving up"). Não teve efeito — mesmo
    // erro idêntico mesmo com os bits setados. O backend gfxstream no
    // macOS aparentemente não expõe uma superfície EGL funcional mesmo
    // tendo os símbolos GLES compilados; a causa raiz está mais profunda
    // no lado do host, fora do escopo de uma flag. Revertido para o
    // estado validado (Vulkan-only).
    krun_check!(krun_set_gpu_options2(
        ctx,
        VIRGLRENDERER_USE_EXTERNAL_BLOB,
        256 * 1024 * 1024
    ));
    info!("GPU: gfxstream Vulkan-only + external blob, 256 MiB vRAM");

    if !args.no_display {
        // Display headless.
        //
        // libkrun retains `create_userdata` (the HeadlessDisplay pointer) for the
        // lifetime of the VM and dereferences it later, from the GPU worker thread,
        // every time the guest flushes a scanout (headless_create copies it into the
        // display `instance`, then headless_alloc_frame reads `disp.frame_buf`). So
        // the HeadlessDisplay must outlive this function. A plain `Box` local here
        // is dropped when `setup` returns -- long before the VM runs -- leaving
        // libkrun with a dangling pointer; its freed slot then gets reused (observed:
        // by the CString just below at `vsock_path`), so `frame_buf.as_mut_ptr()`
        // returns garbage and the first real scanout flush at compose time does a
        // memcpy into a bogus address -> SIGSEGV in VirtioGpuResource::TransferWithIov.
        // This crash only surfaced once the composer fixes (gfxstream 0011/0012) let
        // compose actually reach scanout flush; the use-after-free was always here.
        //
        // Leak it: it must live for the whole process (the VM runs until
        // krun_start_enter returns, after which the process exits), so a one-time
        // intentional leak is the correct lifetime, not a scoped Box.
        let disp: &'static mut HeadlessDisplay = Box::leak(Box::new(HeadlessDisplay::new()));
        let disp_ptr = disp as *mut HeadlessDisplay as *mut c_void;

        let backend = krun_display_backend {
            features: KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER,
            create_userdata: disp_ptr,
            create: Some(headless_create),
            vtable: krun_display_vtable {
                basic_framebuffer: std::mem::ManuallyDrop::new(
                    krun_display_basic_framebuffer_vtable {
                        destroy: None,
                        disable_scanout: Some(headless_disable_scanout),
                        configure_scanout: Some(headless_configure_scanout),
                        alloc_frame: Some(headless_alloc_frame),
                        present_frame: Some(headless_present_frame),
                    },
                ),
            },
        };

        let _display_id = krun_check_u32!(krun_add_display(ctx, args.width, args.height));
        info!("Display: headless {}x{}", args.width, args.height);

        krun_check!(krun_set_display_backend(
            ctx,
            &backend as *const krun_display_backend as *const c_void,
            std::mem::size_of::<krun_display_backend>()
        ));
    } else {
        info!("Display: disabled (--no-display)");
    }

    if let Some(tpm_socket) = args.tpm_socket.as_ref() {
        // TODO: krun_set_tpm_socket está declarado em libkrun.h mas não tem
        // implementação FFI na árvore vendorizada de vendor/libkrun/src — não
        // há símbolo exportado em libkrun.dylib. Desabilitado temporariamente
        // para não quebrar o link; achado em 2026-06-19, não relacionado ao
        // fix de GLES desta sessão.
        let _ = tpm_socket;
        // let tpm_socket_cstr = CString::new(tpm_socket.as_str()).context("tpm socket path")?;
        // krun_check!(krun_set_tpm_socket(ctx, tpm_socket_cstr.as_ptr()));
        // info!("TPM: swtpm socket {tpm_socket}");
        warn!("TPM solicitado via --tpm-socket, mas krun_set_tpm_socket não está disponível (sem impl FFI no libkrun vendorizado) — ignorando.");
    }

    // vsock ADB
    start_adb_bridge("/tmp/capy-adb-5555.sock", "127.0.0.1:5555")?;
    let vsock_path = CString::new("/tmp/capy-adb-5555.sock").context("vsock path")?;
    krun_check!(krun_add_vsock_port2(ctx, 5555, vsock_path.as_ptr(), true));
    info!("vsock: ADB port 5555 via /tmp/capy-adb-5555.sock and tcp 127.0.0.1:5555");

    let console_path = CString::new("/tmp/capy-console.log").unwrap();
    krun_check!(krun_set_console_output(ctx, console_path.as_ptr()));

    let (serial_in_fd, serial_out_fd) = setup_serial_capture("/tmp/capy-console.log")?;
    krun_check!(krun_add_serial_console_default(
        ctx,
        serial_in_fd,
        serial_out_fd,
    ));

    info!("Boot contract: {}", contract.summary());

    if !contract.soc.disks.is_empty() {
        let add_disk = get_krun_add_disk().context(
            "libkrun foi compilado sem BLK; recoloque com suporte a blk para usar --disk",
        )?;
        for (i, disk) in contract.soc.disks.iter().enumerate() {
            let block_id = CString::new(disk.name.as_str()).unwrap();
            let disk_cstr = CString::new(disk.path.as_str()).context("disk path")?;
            krun_check!(add_disk(ctx, block_id.as_ptr(), disk_cstr.as_ptr(), false));
            info!("Disk {}: {}={}", i, disk.name, disk.path);
        }
    }

    if let Some(root) = contract.root.as_ref() {
        // ── Modo libkrunfw ──────────────────────────────────────────────────
        let root_cstr = CString::new(root.as_str()).context("root path")?;
        krun_check!(krun_set_root(ctx, root_cstr.as_ptr()));
        info!("Root: {root}");

        let exec = contract.exec.as_deref().unwrap_or("/bin/sh");
        let exec_cstr = CString::new(exec).context("exec path")?;

        // Construir argv — APENAS exec_args (krun-init prepende exec_path
        // via KRUN_INIT automaticamente; incluí-lo aqui de novo duplica
        // argv[0], e o ash tenta interpretar argv[1]="/bin/sh" duplicado
        // como SCRIPT FILE — lendo o ELF do busybox como texto, daí o
        // "syntax error: unexpected '('" nos bytes binários)
        let mut argv_cstrings: Vec<CString> = Vec::new();
        for a in &contract.exec_args {
            argv_cstrings.push(CString::new(a.as_str()).context("exec arg")?);
        }
        let mut argv_ptrs: Vec<*const c_char> = argv_cstrings.iter().map(|s| s.as_ptr()).collect();
        argv_ptrs.push(null());

        // envp mínimo — evita injetar DYLD_LIBRARY_PATH no kernel cmdline
        // (estoura o limite de 2048 bytes do aarch64 cmdline)
        let env_home = CString::new("HOME=/root").unwrap();
        let env_path = CString::new("PATH=/bin:/usr/bin:/sbin:/usr/sbin").unwrap();
        let env_term = CString::new("TERM=xterm").unwrap();
        let envp_ptrs: Vec<*const c_char> = vec![
            env_home.as_ptr(),
            env_path.as_ptr(),
            env_term.as_ptr(),
            null(),
        ];

        krun_check!(krun_set_exec(
            ctx,
            exec_cstr.as_ptr(),
            argv_ptrs.as_ptr(),
            envp_ptrs.as_ptr(),
        ));
        info!("Exec: {exec}");
    }

    if let Some(root_disk) = contract.root_disk.as_ref() {
        // ── Modo block-root (SP-3b) ─────────────────────────────────────────
        let root_disk_cstr = CString::new(root_disk.as_str()).context("root disk path")?;
        let set_root_disk = get_krun_set_root_disk().context(
            "libkrun foi compilado sem BLK; recoloque com suporte a blk para usar --root-disk",
        )?;
        krun_check!(set_root_disk(ctx, root_disk_cstr.as_ptr()));
        info!("Root disk: {root_disk}");
    }

    if let Some(kernel) = contract.kernel.as_ref() {
        // ── Modo kernel externo ─────────────────────────────────────────────
        let kernel_cstr = CString::new(kernel.path.as_str()).context("kernel path")?;
        let initrd_cstr = kernel
            .initramfs
            .as_deref()
            .map(|s| CString::new(s).context("initramfs path"))
            .transpose()?;
        let cmdline_cstr = CString::new(kernel.cmdline.as_str()).context("cmdline")?;

        krun_check!(krun_set_kernel(
            ctx,
            kernel_cstr.as_ptr(),
            KRUN_KERNEL_FORMAT_IMAGE,
            initrd_cstr.as_ref().map_or(null(), |s| s.as_ptr()),
            cmdline_cstr.as_ptr(),
        ));
        let ttys0 = CString::new("ttyS0").unwrap();
        krun_check!(krun_set_kernel_console(ctx, ttys0.as_ptr()));
        info!("Kernel: {}", kernel.path);
    }

    info!("Booting VM...");
    krun_check!(krun_start_enter(ctx));
    Ok(())
}

fn validate_transport(args: &Args, contract: &BootContract) -> anyhow::Result<()> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let android_external_kernel =
            contract.kernel.is_some() && contract.soc.uses_android_partition_map();

        if android_external_kernel && !args.allow_transport_mismatch {
            bail!(
                "Android partitioned boot on macOS/aarch64 is blocked before init: the current libkrun backend exposes virtio devices via MMIO/FDT only, while this guest layout was prepared for a PCI-style virtio machine. No guest block device will enumerate, so first-stage init times out before adb. Re-run with --allow-transport-mismatch to keep debugging this known-broken path, or switch to an Android guest/kernel that supports virtio-mmio."
            );
        }

        if android_external_kernel {
            info!(
                "Transport override enabled: continuing with known MMIO-only backend for Android partitioned boot"
            );
        }
    }

    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    let _ = (args, contract);

    Ok(())
}

fn build_boot_contract(args: &Args) -> anyhow::Result<BootContract> {
    let mode_root = args.root.is_some();
    let mode_root_disk = args.root_disk.is_some();
    let mode_kernel = args.kernel.is_some();
    if !mode_root && !mode_root_disk && !mode_kernel {
        bail!("Especifique --root <dir>, --root-disk <img> ou --kernel <Image>");
    }
    if mode_root && (mode_root_disk || mode_kernel) {
        bail!("--root não pode ser combinado com --root-disk ou --kernel");
    }

    let soc = SocModel::from_disk_specs(&args.disk).descriptor();
    let kernel = if mode_kernel {
        let path = args.kernel.clone().unwrap();
        let mut cmdline = args.cmdline.clone();
        let has_userdata = soc.disks.iter().any(|disk| disk.role == DiskRole::Userdata);
        // frp is attached as a separate --disk frp=<img> (not a partition inside the super
        // GPT); it always lands right after super+userdata in attach order, since those are
        // the only two disks with a lower DiskRole::priority() in the configurations we boot
        // today -- see soc.rs.
        let has_frp = soc.disks.iter().any(|disk| disk.role == DiskRole::Frp);
        let partition_map = if soc.uses_android_partition_map() {
            let mut entries = vec![
                "vda1,boot_a",
                "vda2,init_boot_a",
                "vda3,metadata",
                "vda4,super",
                "vda5,vbmeta_a",
                "vda6,vbmeta_system_a",
                "vda7,vbmeta_system_dlkm_a",
                "vda8,vbmeta_vendor_dlkm_a",
                "vda9,vendor_boot_a",
                "vda10,misc",
            ];
            if has_userdata {
                entries.push("vdb,userdata");
            }
            if has_frp {
                entries.push("vdc,frp");
            }
            Some(format!("androidboot.partition_map={}", entries.join(";")))
        } else {
            None
        };
        for hint in [
            format!("androidboot.hardware={}", soc.hardware),
            "androidboot.hardware.egl=emulation".to_string(),
            "androidboot.hardware.gralloc=minigbm".to_string(),
            "androidboot.hardware.hwcomposer=ranchu".to_string(),
            "androidboot.hardware.vulkan=ranchu".to_string(),
            "androidboot.hardware.gltransport=virtio-gpu-pipe".to_string(),
            // Cuttlefish lights HAL binds an AF_VSOCK listener on this port
            // (VsockServer::new). With the property absent it defaults to port 0,
            // which fails the bind with EACCES and panics, leaving the VINTF-declared
            // android.hardware.light.ILights service unregistered -- LightsService in
            // system_server then blocks in waitForDeclaredService until Watchdog kills
            // it, crash-looping zygote and preventing sys.boot_completed. Any nonzero
            // port lets the guest-side listener bind succeed (no host peer needed to
            // register the service), so boot can complete.
            "androidboot.vsock_lights_port=6800".to_string(),
            "androidboot.mode=normal".to_string(),
            format!("androidboot.bootmode={}", soc.bootmode),
            format!("androidboot.slot_suffix={}", soc.slot_suffix),
            format!("androidboot.fstab_suffix={}", soc.fstab_suffix),
            "printk.devkmsg=on".to_string(),
            "printk.time=1".to_string(),
            "androidboot.force_normal_boot=1".to_string(),
            "androidboot.super_partition=super".to_string(),
            "androidboot.vbmeta.device_state=unlocked".to_string(),
            "ro.boot.verifiedbootstate=orange".to_string(),
            "ro.boot.flash.locked=0".to_string(),
            "androidboot.verifiedbootstate=orange".to_string(),
            "androidboot.veritymode=disabled".to_string(),
            format!("androidboot.boot_devices={}", soc.boot_devices.join(",")),
        ] {
            if !cmdline.contains(&hint) {
                if !cmdline.is_empty() {
                    cmdline.push(' ');
                }
                cmdline.push_str(&hint);
            }
        }
        if let Some(hint) = partition_map {
            if !cmdline.contains(&hint) {
                if !cmdline.is_empty() {
                    cmdline.push(' ');
                }
                cmdline.push_str(&hint);
            }
        }
        info!(
            "Kernel cmdline includes partition_map: {}",
            cmdline.contains("androidboot.partition_map=")
        );
        Some(KernelImage {
            path,
            initramfs: args.initramfs.clone(),
            cmdline,
        })
    } else {
        None
    };

    Ok(BootContract {
        soc,
        root: args.root.clone(),
        root_disk: args.root_disk.clone(),
        kernel,
        exec: args.exec.clone(),
        exec_args: args.exec_args.clone(),
    })
}

fn main() {
    let args = Args::parse();

    env_logger::builder()
        .filter_level(if args.verbose {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Info
        })
        .init();

    if let Err(e) = boot(&args) {
        error!("{e:#}");
        std::process::exit(1);
    }
}
