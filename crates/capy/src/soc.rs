#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum DiskRole {
    Boot,
    InitBoot,
    VendorBoot,
    Vbmeta,
    VbmetaSystem,
    VbmetaVendorDlkm,
    VbmetaSystemDlkm,
    Super,
    Userdata,
    Metadata,
    Misc,
    Frp,
    Other,
}

impl DiskRole {
    pub fn from_name(name: &str) -> Self {
        match name {
            "boot" | "boot_a" => Self::Boot,
            "init_boot" | "init_boot_a" => Self::InitBoot,
            "vendor_boot" | "vendor_boot_a" => Self::VendorBoot,
            "vbmeta" | "vbmeta_a" => Self::Vbmeta,
            "vbmeta_system" | "vbmeta_system_a" => Self::VbmetaSystem,
            "vbmeta_vendor_dlkm" | "vbmeta_vendor_dlkm_a" => Self::VbmetaVendorDlkm,
            "vbmeta_system_dlkm" | "vbmeta_system_dlkm_a" => Self::VbmetaSystemDlkm,
            "super" => Self::Super,
            "userdata" => Self::Userdata,
            "metadata" => Self::Metadata,
            "misc" => Self::Misc,
            "frp" => Self::Frp,
            _ => Self::Other,
        }
    }

    fn priority(self) -> u8 {
        match self {
            Self::Boot => 0,
            Self::InitBoot => 1,
            Self::VendorBoot => 2,
            Self::Vbmeta => 3,
            Self::VbmetaSystem => 4,
            Self::VbmetaVendorDlkm => 5,
            Self::VbmetaSystemDlkm => 6,
            Self::Super => 7,
            Self::Userdata => 8,
            Self::Metadata => 9,
            Self::Misc => 10,
            Self::Frp => 11,
            Self::Other => 255,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SoCDescriptor {
    pub abi_version: u32,
    pub slot_suffix: String,
    pub disks: Vec<SocDisk>,
    pub hardware: String,
    pub bootmode: String,
    pub boot_devices: Vec<String>,
    pub bootdevice: Option<String>,
    pub fstab_suffix: String,
}

#[derive(Debug, Clone)]
pub struct KernelImage {
    pub path: String,
    pub initramfs: Option<String>,
    pub cmdline: String,
}

#[derive(Debug, Clone)]
pub struct BootContract {
    pub soc: SoCDescriptor,
    pub root: Option<String>,
    pub root_disk: Option<String>,
    pub kernel: Option<KernelImage>,
    pub exec: Option<String>,
    pub exec_args: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct SocDisk {
    pub name: String,
    pub path: String,
    pub role: DiskRole,
}

pub struct SocModel {
    disks: Vec<SocDisk>,
}

impl SocModel {
    pub fn from_disk_specs(specs: &[String]) -> Self {
        let mut disks = Vec::with_capacity(specs.len());
        for (i, spec) in specs.iter().enumerate() {
            let (name, path) = if let Some((name, path)) = spec.split_once('=') {
                (name.to_string(), path.to_string())
            } else if let Some((name, path)) = spec.split_once(':') {
                (name.to_string(), path.to_string())
            } else {
                (
                    format!("vd{}", (b'a' + (i as u8)) as char),
                    spec.to_string(),
                )
            };
            let role = DiskRole::from_name(&name);
            let name = match role {
                DiskRole::Boot
                | DiskRole::InitBoot
                | DiskRole::VendorBoot
                | DiskRole::Vbmeta
                | DiskRole::VbmetaSystem
                | DiskRole::VbmetaVendorDlkm
                | DiskRole::VbmetaSystemDlkm => {
                    if name.ends_with("_a") {
                        name
                    } else {
                        format!("{name}_a")
                    }
                }
                _ => name,
            };
            disks.push(SocDisk { name, path, role });
        }
        Self { disks }
    }

    pub fn descriptor(&self) -> SoCDescriptor {
        let mut disks = self.disks.clone();
        disks.sort_by_key(|disk| (disk.role.priority(), disk.name.clone()));
        let single_disk = disks.len() == 1;
        let has_super = disks.iter().any(|disk| disk.role == DiskRole::Super);

        let mut boot_devices = disks
            .iter()
            .filter_map(|disk| match disk.role {
                DiskRole::Boot => Some("vda".to_string()),
                DiskRole::InitBoot => Some("vdb".to_string()),
                DiskRole::VendorBoot => Some("vdc".to_string()),
                DiskRole::Super => Some(if single_disk {
                    "vda".to_string()
                } else {
                    "vdj".to_string()
                }),
                DiskRole::Userdata => Some(if has_super {
                    "vdb".to_string()
                } else {
                    "vda".to_string()
                }),
                DiskRole::Metadata => Some("vdj".to_string()),
                DiskRole::Misc => Some("vdk".to_string()),
                DiskRole::Frp => Some("vdc".to_string()),
                DiskRole::Vbmeta
                | DiskRole::VbmetaSystem
                | DiskRole::VbmetaVendorDlkm
                | DiskRole::VbmetaSystemDlkm
                | DiskRole::Other => None,
            })
            .collect::<Vec<_>>();
        if disks.iter().any(|disk| disk.role != DiskRole::Other) {
            boot_devices.extend([
                "vda_a".to_string(),
                "vdb_a".to_string(),
                "vdj".to_string(),
                "vdj_a".to_string(),
                "a004000.virtio_mmio".to_string(),
                "0a004000.virtio_mmio".to_string(),
                "a005000.virtio_mmio".to_string(),
                "0a005000.virtio_mmio".to_string(),
                "a006000.virtio_mmio".to_string(),
                "0a006000.virtio_mmio".to_string(),
                "a007000.virtio_mmio".to_string(),
                "0a007000.virtio_mmio".to_string(),
                "a008000.virtio_mmio".to_string(),
                "0a008000.virtio_mmio".to_string(),
                "a009000.virtio_mmio".to_string(),
                "0a009000.virtio_mmio".to_string(),
            ]);
        }
        let mut seen = std::collections::BTreeSet::new();
        boot_devices.retain(|dev| seen.insert(dev.clone()));
        let bootdevice = boot_devices.first().cloned();

        SoCDescriptor {
            abi_version: 1,
            slot_suffix: "_a".to_string(),
            disks,
            hardware: "cf".to_string(),
            bootmode: "normal".to_string(),
            boot_devices,
            bootdevice,
            fstab_suffix: "cf.f2fs.hctr2".to_string(),
        }
    }
}

impl SoCDescriptor {
    pub fn uses_android_partition_map(&self) -> bool {
        self.disks.iter().any(|disk| disk.role != DiskRole::Other)
    }

    pub fn summary(&self) -> String {
        let names = self
            .disks
            .iter()
            .map(|disk| format!("{}={}", disk.name, disk.path))
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "abi v{} slot={} hw={} bootmode={} boot_devices={:?} disks=[{}]",
            self.abi_version,
            self.slot_suffix,
            self.hardware,
            self.bootmode,
            self.boot_devices,
            names
        )
    }
}

impl BootContract {
    pub fn summary(&self) -> String {
        let mode = if self.kernel.is_some() {
            "kernel"
        } else if self.root_disk.is_some() {
            "root-disk"
        } else if self.root.is_some() {
            "root"
        } else {
            "unknown"
        };

        format!("mode={} soc={{ {} }}", mode, self.soc.summary())
    }
}

#[cfg(test)]
mod tests {
    use super::{DiskRole, SocModel};

    #[test]
    fn canonicalizes_disk_order() {
        let specs = vec![
            "userdata=/tmp/userdata.img".to_string(),
            "boot=/tmp/boot.img".to_string(),
            "misc=/tmp/misc.img".to_string(),
            "super=/tmp/super.img".to_string(),
        ];

        let descriptor = SocModel::from_disk_specs(&specs).descriptor();
        let roles: Vec<DiskRole> = descriptor.disks.iter().map(|disk| disk.role).collect();

        assert_eq!(
            roles,
            vec![
                DiskRole::Boot,
                DiskRole::Super,
                DiskRole::Userdata,
                DiskRole::Misc
            ]
        );
        assert_eq!(descriptor.abi_version, 1);
        assert_eq!(descriptor.slot_suffix, "_a");
    }

    #[test]
    fn builds_android_device_graph() {
        let specs = vec![
            "boot=/tmp/boot.img".to_string(),
            "init_boot=/tmp/init_boot.img".to_string(),
            "vendor_boot=/tmp/vendor_boot.img".to_string(),
            "super=/tmp/super.img".to_string(),
            "userdata=/tmp/userdata.img".to_string(),
            "metadata=/tmp/metadata.img".to_string(),
            "misc=/tmp/misc.img".to_string(),
        ];

        let adgc = SocModel::from_disk_specs(&specs).descriptor();

        assert_eq!(adgc.hardware, "cf");
        assert_eq!(adgc.bootmode, "normal");
        assert_eq!(adgc.slot_suffix, "_a");
        assert_eq!(adgc.bootdevice.as_deref(), Some("vda"));
        assert!(adgc.boot_devices.contains(&"vda".to_string()));
        assert!(adgc.boot_devices.contains(&"vdb".to_string()));
        assert!(adgc.boot_devices.contains(&"vdc".to_string()));
        assert!(adgc.boot_devices.contains(&"vdj".to_string()));
        assert_eq!(adgc.fstab_suffix, "cf.f2fs.hctr2");
    }

    #[test]
    fn defaults_unlabeled_disks_to_other() {
        let specs = vec!["/tmp/disk.img".to_string()];
        let descriptor = SocModel::from_disk_specs(&specs).descriptor();

        assert_eq!(descriptor.disks.len(), 1);
        assert_eq!(descriptor.disks[0].role, DiskRole::Other);
        assert_eq!(descriptor.disks[0].name, "vda");
        assert!(!descriptor.uses_android_partition_map());
    }

    #[test]
    fn detects_android_partition_map() {
        let specs = vec![
            "boot=/tmp/boot.img".to_string(),
            "super=/tmp/super.img".to_string(),
        ];

        let descriptor = SocModel::from_disk_specs(&specs).descriptor();

        assert!(descriptor.uses_android_partition_map());
    }
}
