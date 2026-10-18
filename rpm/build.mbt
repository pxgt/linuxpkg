///|
/// One file of the package with everything the header needs to know.
priv struct FileItem {
  path : String
  key : Bytes
  entry : @spec.Entry
  size : Int32
  mode : Int32
  digest : String
  link : String
}

///|
fn sha256_hex(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}

///|
fn compare_bytes(a : Bytes, b : Bytes) -> Int32 {
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<shared {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}

///|
/// `epoch:version-release`, or `version-release` without an epoch.
fn evr(spec : @spec.PackageSpec) -> String {
  let base = "\{spec.version}-\{spec.release}"
  if spec.epoch > 0 {
    "\{spec.epoch}:\{base}"
  } else {
    base
  }
}

///|
/// The conventional file name, for example `hello-1.0.0-1.noarch.rpm`.
pub fn file_name(spec : @spec.PackageSpec) -> String {
  "\{spec.name}-\{spec.version}-\{spec.release}.\{spec.arch.rpm_name()}.rpm"
}

///|
fn sense_flags(op : @spec.VersionOp) -> Int32 {
  match op {
    Lt => SENSE_LESS
    Le => SENSE_LESS | SENSE_EQUAL
    Eq => SENSE_EQUAL
    Ge => SENSE_GREATER | SENSE_EQUAL
    Gt => SENSE_GREATER
  }
}

///|
/// A set of dependencies as the three parallel tags (name, flags, version).
priv struct Relations {
  names : Array[String]
  flags : Array[Int32]
  versions : Array[String]
}

///|
fn Relations::new() -> Relations {
  { names: [], flags: [], versions: [], }
}

///|
fn Relations::add(
  self : Relations,
  name : String,
  flags : Int32,
  version : String,
) -> Unit {
  self.names.push(name)
  self.flags.push(flags)
  self.versions.push(version)
}

///|
fn Relations::from(items : Array[@spec.Dependency]) -> Relations {
  let relations = Relations::new()
  for item in items {
    match item.constraint {
      Some((op, version)) => relations.add(item.name, sense_flags(op), version)
      None => relations.add(item.name, 0, "")
    }
  }
  relations
}

///|
/// Sort by name (byte order), keeping the order of equal names.
fn Relations::sorted(self : Relations) -> Relations {
  let order : Array[Int32] = []
  for i in 0..<self.names.length() {
    order.push(i)
  }
  order.sort_by((a, b) => {
    let c = compare_bytes(
      @utf8.encode(self.names[a]),
      @utf8.encode(self.names[b]),
    )
    if c != 0 {
      c
    } else {
      a - b
    }
  })
  {
    names: order.map(i => self.names[i]),
    flags: order.map(i => self.flags[i]),
    versions: order.map(i => self.versions[i]),
  }
}

///|
fn Relations::push_tags(
  self : Relations,
  tags : Array[Tag],
  name_tag : Int32,
  flags_tag : Int32,
  version_tag : Int32,
) -> Unit {
  if self.names.length() > 0 {
    let sorted = self.sorted()
    tags.push({ id: name_tag, value: StrArray(sorted.names), })
    tags.push({ id: flags_tag, value: Int32(sorted.flags), })
    tags.push({ id: version_tag, value: StrArray(sorted.versions), })
  }
}

///|
fn file_mode(entry : @spec.Entry) -> Int32 {
  match entry.kind {
    File(_) => 0o100000 | entry.mode
    Dir => 0o040000 | entry.mode
    Symlink(_) => 0o120777
  }
}

///|
fn collect_files(spec : @spec.PackageSpec) -> Array[FileItem] raise RpmError {
  let items : Array[FileItem] = []
  for entry in spec.entries {
    let (size, digest, link) = match entry.kind {
      File(content) => (content.length(), sha256_hex(content), "")
      Dir => (0, "", "")
      Symlink(target) => (@utf8.encode(target).length(), "", target)
    }
    if size > 2147483647 {
      raise RpmError::Invalid(
        field=entry.path,
        message="files larger than 2 GiB are not supported",
      )
    }
    items.push({
      path: entry.path,
      key: @utf8.encode(entry.path),
      entry,
      size,
      mode: file_mode(entry),
      digest,
      link,
    })
  }
  items.sort_by((a, b) => compare_bytes(a.key, b.key))
  items
}

///|
/// `/usr/bin/hello` is split into `/usr/bin/` and `hello`.
fn split_path(path : String) -> (String, String) {
  let mut cut = 0
  for i in 0..<path.length() {
    if path[i] == '/' {
      cut = i
    }
  }
  (path[0:cut + 1].to_owned(), path[cut + 1:].to_owned())
}

///|
fn mtime_of(entry : @spec.Entry, default_mtime : Int64) -> Int32 raise RpmError {
  let t = match entry.mtime {
    Some(t) => t
    None => default_mtime
  }
  if t > 2147483647L {
    raise RpmError::Invalid(
      field=entry.path,
      message="modification time \{t} does not fit in 32 bits",
    )
  }
  t.to_int()
}

///|
fn file_tags(
  spec : @spec.PackageSpec,
  files : Array[FileItem],
  tags : Array[Tag],
) -> Unit raise RpmError {
  if files.length() == 0 {
    return
  }
  let dir_names : Array[String] = []
  let dir_index : Map[String, Int32] = Map([])
  let basenames : Array[String] = []
  let dir_indexes : Array[Int32] = []
  for item in files {
    let (dir, base) = split_path(item.path)
    let index = match dir_index.get(dir) {
      Some(i) => i
      None => {
        let i = dir_names.length()
        dir_names.push(dir)
        dir_index[dir] = i
        i
      }
    }
    basenames.push(base)
    dir_indexes.push(index)
  }
  tags.push({ id: TAG_BASENAMES, value: StrArray(basenames), })
  tags.push({ id: TAG_DIRNAMES, value: StrArray(dir_names), })
  tags.push({ id: TAG_DIRINDEXES, value: Int32(dir_indexes), })
  tags.push({ id: TAG_FILESIZES, value: Int32(files.map(f => f.size)), })
  tags.push({ id: TAG_FILEMODES, value: Int16(files.map(f => f.mode)), })
  tags.push({ id: TAG_FILERDEVS, value: Int16(files.map(_ => 0)), })
  let mtimes : Array[Int32] = []
  for item in files {
    mtimes.push(mtime_of(item.entry, spec.mtime))
  }
  tags.push({ id: TAG_FILEMTIMES, value: Int32(mtimes), })
  tags.push({ id: TAG_FILEDIGESTS, value: StrArray(files.map(f => f.digest)), })
  tags.push({ id: TAG_FILELINKTOS, value: StrArray(files.map(f => f.link)), })
  tags.push({
    id: TAG_FILEFLAGS,
    value: Int32(files.map(f => if f.entry.config { FILE_CONFIG } else { 0 })),
  })
  tags.push({
    id: TAG_FILEUSERNAME,
    value: StrArray(files.map(f => f.entry.owner)),
  })
  tags.push({
    id: TAG_FILEGROUPNAME,
    value: StrArray(files.map(f => f.entry.group)),
  })
  tags.push({ id: TAG_FILEVERIFYFLAGS, value: Int32(files.map(_ => -1)), })
  tags.push({ id: TAG_FILEDEVICES, value: Int32(files.map(_ => 1)), })
  let inodes : Array[Int32] = []
  for i in 0..<files.length() {
    inodes.push(i + 1)
  }
  tags.push({ id: TAG_FILEINODES, value: Int32(inodes), })
  tags.push({ id: TAG_FILELANGS, value: StrArray(files.map(_ => "")), })
  tags.push({ id: TAG_FILEDIGESTALGO, value: Int32([DIGEST_SHA256]), })
}

///|
fn script_tags(spec : @spec.PackageSpec, tags : Array[Tag]) -> Unit {
  let add = (script : String?, body : Int32, prog : Int32) => {
    match script {
      Some(text) => {
        tags.push({ id: body, value: Str(text), })
        tags.push({ id: prog, value: StrArray(["/bin/sh"]), })
      }
      None => ()
    }
  }
  add(spec.scripts.pre_install, TAG_PREIN, TAG_PREINPROG)
  add(spec.scripts.post_install, TAG_POSTIN, TAG_POSTINPROG)
  add(spec.scripts.pre_remove, TAG_PREUN, TAG_PREUNPROG)
  add(spec.scripts.post_remove, TAG_POSTUN, TAG_POSTUNPROG)
}

///|
fn relation_tags(spec : @spec.PackageSpec, tags : Array[Tag]) -> Unit {
  let provides = Relations::from(spec.provides)
  provides.add(spec.name, SENSE_EQUAL, evr(spec))
  provides.push_tags(
    tags,
    TAG_PROVIDENAME,
    TAG_PROVIDEFLAGS,
    TAG_PROVIDEVERSION,
  )
  let requires = Relations::from(spec.depends)
  // Features of the package format we rely on; old rpm versions refuse to
  // install the package instead of mis-reading it.
  let rpmlib = SENSE_RPMLIB | SENSE_LESS | SENSE_EQUAL
  requires.add("rpmlib(CompressedFileNames)", rpmlib, "3.0.4-1")
  requires.add("rpmlib(FileDigests)", rpmlib, "4.6.0-1")
  requires.add("rpmlib(PayloadFilesHavePrefix)", rpmlib, "4.0-1")
  requires.push_tags(
    tags,
    TAG_REQUIRENAME,
    TAG_REQUIREFLAGS,
    TAG_REQUIREVERSION,
  )
  Relations::from(spec.conflicts).push_tags(
    tags,
    TAG_CONFLICTNAME,
    TAG_CONFLICTFLAGS,
    TAG_CONFLICTVERSION,
  )
  Relations::from(spec.replaces).push_tags(
    tags,
    TAG_OBSOLETENAME,
    TAG_OBSOLETEFLAGS,
    TAG_OBSOLETEVERSION,
  )
  Relations::from(spec.recommends).push_tags(
    tags,
    TAG_RECOMMENDNAME,
    TAG_RECOMMENDFLAGS,
    TAG_RECOMMENDVERSION,
  )
  Relations::from(spec.suggests).push_tags(
    tags,
    TAG_SUGGESTNAME,
    TAG_SUGGESTFLAGS,
    TAG_SUGGESTVERSION,
  )
}

///|
fn payload_entries(
  spec : @spec.PackageSpec,
  files : Array[FileItem],
) -> Array[@cpio.Entry] raise RpmError {
  let entries : Array[@cpio.Entry] = []
  for i, item in files {
    let path = "." + item.path
    let mtime = mtime_of(item.entry, spec.mtime).to_int64()
    let entry = match item.entry.kind {
      File(content) =>
        @cpio.Entry::file(path, content, mode=item.mode, mtime~, ino=i + 1)
      Dir => @cpio.Entry::dir(path, mode=item.mode, mtime~, ino=i + 1)
      Symlink(target) => @cpio.Entry::symlink(path, target, mtime~, ino=i + 1)
    }
    entries.push(entry)
  }
  entries
}

///|
fn summary_of(description : String) -> String {
  match description.split("\n").next() {
    Some(line) => line.trim().to_owned()
    None => ""
  }
}

///|
fn main_header(
  spec : @spec.PackageSpec,
  files : Array[FileItem],
  payload_digest : String,
) -> Header raise RpmError {
  let tags : Array[Tag] = []
  tags.push({ id: TAG_I18N_TABLE, value: StrArray(["C"]), })
  tags.push({ id: TAG_NAME, value: Str(spec.name), })
  tags.push({ id: TAG_VERSION, value: Str(spec.version), })
  tags.push({ id: TAG_RELEASE, value: Str(spec.release), })
  if spec.epoch > 0 {
    tags.push({ id: TAG_EPOCH, value: Int32([spec.epoch]), })
  }
  tags.push({ id: TAG_SUMMARY, value: I18n([summary_of(spec.description)]), })
  tags.push({
    id: TAG_DESCRIPTION,
    value: I18n([spec.description.trim().to_owned()]),
  })
  if spec.mtime > 2147483647L {
    raise RpmError::Invalid(
      field="mtime",
      message="\{spec.mtime} does not fit in 32 bits",
    )
  }
  tags.push({ id: TAG_BUILDTIME, value: Int32([spec.mtime.to_int()]), })
  tags.push({ id: TAG_BUILDHOST, value: Str("localhost"), })
  let mut total = 0
  for item in files {
    if item.entry.kind is File(_) {
      total += item.size
      if total < 0 {
        raise RpmError::Invalid(
          field="size",
          message="the installed size does not fit in 32 bits",
        )
      }
    }
  }
  tags.push({ id: TAG_SIZE, value: Int32([total]), })
  match spec.vendor {
    Some(v) => tags.push({ id: TAG_VENDOR, value: Str(v), })
    None => ()
  }
  tags.push({
    id: TAG_LICENSE,
    value: Str(
      match spec.license {
        Some(l) => l
        None => "Unspecified"
      },
    ),
  })
  tags.push({ id: TAG_PACKAGER, value: Str(spec.maintainer), })
  tags.push({ id: TAG_GROUP, value: I18n([spec.section]), })
  match spec.homepage {
    Some(u) => tags.push({ id: TAG_URL, value: Str(u), })
    None => ()
  }
  tags.push({ id: TAG_OS, value: Str("linux"), })
  tags.push({ id: TAG_ARCH, value: Str(spec.arch.rpm_name()), })
  tags.push({ id: TAG_SOURCERPM, value: Str("(none)"), })
  file_tags(spec, files, tags)
  script_tags(spec, tags)
  relation_tags(spec, tags)
  tags.push({ id: TAG_PAYLOADFORMAT, value: Str("cpio"), })
  tags.push({ id: TAG_PAYLOADCOMPRESSOR, value: Str("gzip"), })
  tags.push({ id: TAG_PAYLOADFLAGS, value: Str("9"), })
  tags.push({ id: TAG_PAYLOADDIGEST, value: StrArray([payload_digest]), })
  tags.push({ id: TAG_PAYLOADDIGESTALGO, value: Int32([DIGEST_SHA256]), })
  { region: Some(REGION_IMMUTABLE), tags, }
}

///|
fn lead(spec : @spec.PackageSpec) -> Bytes {
  let out = Buffer(size_hint=96)
  out.write_bytes(b"\xed\xab\xee\xdb")
  // major 3, minor 0, type 0 (binary), arch number 1, ...
  out.write_bytes(b"\x03\x00\x00\x00\x00\x01")
  let label = @utf8.encode("\{spec.name}-\{spec.version}-\{spec.release}")
  let shown = if label.length() > 65 { label[0:65].to_owned() } else { label }
  out.write_bytes(shown)
  out.write_bytes(Bytes::make(66 - shown.length(), b'\x00'))
  // os number 1 (Linux), signature type 5 (header style), reserved
  out.write_bytes(b"\x00\x01\x00\x05")
  out.write_bytes(Bytes::make(16, b'\x00'))
  out.to_bytes()
}

///|
/// Build an `.rpm` file from a package description.
///
/// The file is the 96-byte lead, the signature header (size, SHA-256 of the
/// main header and uncompressed payload size; there is no GPG signature), the
/// main header and the gzip compressed cpio payload. The result depends only
/// on `spec`.
pub fn build(spec : @spec.PackageSpec) -> Bytes raise RpmError {
  spec.validate() catch {
    @spec.SpecError::Invalid(field~, message~) =>
      raise RpmError::Invalid(field~, message~)
  }
  if spec.mtime > 2147483647L {
    raise RpmError::Invalid(
      field="mtime",
      message="\{spec.mtime} does not fit in 32 bits",
    )
  }
  let files = collect_files(spec)
  let entries = payload_entries(spec, files)
  let cpio = @cpio.build(entries) catch {
    err => raise RpmError::Invalid(field="payload", message="\{err}")
  }
  let payload = @gzip.compress(cpio)
  let header = main_header(spec, files, sha256_hex(payload)).encode()
  let signature : Header = {
    region: Some(REGION_SIGNATURE),
    tags: [
      { id: SIG_SIZE, value: Int32([header.length() + payload.length()]), },
      { id: SIG_SHA256, value: Str(sha256_hex(header)), },
      { id: SIG_PAYLOADSIZE, value: Int32([cpio.length()]), },
    ],
  }
  let signature_bytes = signature.encode()
  let out = Buffer(size_hint=header.length() + payload.length() + 512)
  out.write_bytes(lead(spec))
  out.write_bytes(signature_bytes)
  // The main header starts at an 8 byte boundary.
  let pad = (8 - signature_bytes.length() % 8) % 8
  out.write_bytes(Bytes::make(pad, b'\x00'))
  out.write_bytes(header)
  out.write_bytes(payload)
  out.to_bytes()
}
