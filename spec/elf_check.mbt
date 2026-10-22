///|
/// The ELF files among the regular files of `contents`: the index of the
/// content item, and what the headers say. A file that starts like an ELF
/// file but cannot be read is skipped here; `linuxpkg elf` reports why.
fn Config::elf_files(
  self : Config,
  files : Map[String, Bytes],
) -> Array[(Int32, Content, @elf.ElfInfo)] {
  let found : Array[(Int32, Content, @elf.ElfInfo)] = []
  for i, content in self.contents {
    match (content.kind, content.src) {
      (File | ConfigFile, Some(path)) =>
        match files.get(path) {
          Some(bytes) if @elf.is_elf(bytes[:]) =>
            try found.push((i, content, @elf.parse(bytes[:]))) catch {
              _ => ()
            } noraise {
              _ => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  found
}

///|
/// Stop if an ELF file in `contents` is built for another CPU than `arch`,
/// for example an arm64 program in an amd64 package. Nothing is checked for
/// architecture independent packages (see `Config::elf_warnings`), for ELF
/// files of a machine that has no package architecture, or when
/// `allow_arch_mismatch` is set.
fn Config::check_elf_arch(
  self : Config,
  files : Map[String, Bytes],
) -> Unit raise SpecError {
  if self.allow_arch_mismatch || self.arch == All {
    return
  }
  for item in self.elf_files(files) {
    let (i, content, info) = item
    match info.arch() {
      Some(name) => {
        let found = Arch::parse(name)
        if found != self.arch {
          raise invalid(
            "contents[\{i}]",
            "\{content.dst} is an ELF file for \{name}, but the package architecture is \{self.arch.deb_name()} (set \"allow_arch_mismatch\": true to build it anyway)",
          )
        }
      }
      None => ()
    }
  }
}

///|
/// Things worth a warning but not an error: an architecture independent
/// package (`all`, `noarch`) that contains ELF files, which are always built
/// for one CPU. Empty when `allow_arch_mismatch` is set.
pub fn Config::elf_warnings(
  self : Config,
  files : Map[String, Bytes],
) -> Array[String] {
  let warnings : Array[String] = []
  if self.allow_arch_mismatch || self.arch != All {
    return warnings
  }
  for item in self.elf_files(files) {
    let (i, content, info) = item
    let cpu = match info.arch() {
      Some(name) => name
      None => @elf.machine_name(info.machine)
    }
    warnings.push(
      "contents[\{i}] \{content.dst} is an ELF file for \{cpu}, but the package architecture is \"all\"",
    )
  }
  warnings
}
