///|
fn escape_xml(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn first_string(h : @rpm.Header, id : Int32) -> String {
  match h.strings(id) {
    [text, ..] => text
    [] => ""
  }
}

///|
/// A numeric tag as a 64-bit number, 0 when absent.
fn number(h : @rpm.Header, id : Int32) -> Int64 {
  match h.get(id) {
    Some(Int64([n, ..])) => n
    Some(Int32([n, ..])) | Some(Int16([n, ..])) | Some(Int8([n, ..])) =>
      n.to_int64()
    _ => 0L
  }
}

///|
const SENSE_LESS : Int32 = 2

///|
const SENSE_GREATER : Int32 = 4

///|
const SENSE_EQUAL : Int32 = 8

///|
/// RPMSENSE_PREREQ, RPMSENSE_SCRIPT_PRE and RPMSENSE_SCRIPT_POST.
const SENSE_PRE : Int32 = 64 + 512 + 1024

///|
fn flag_name(flags : Int32) -> String? {
  let less = (flags & SENSE_LESS) != 0
  let greater = (flags & SENSE_GREATER) != 0
  let equal = (flags & SENSE_EQUAL) != 0
  match (less, greater, equal) {
    (true, false, false) => Some("LT")
    (true, false, true) => Some("LE")
    (false, true, false) => Some("GT")
    (false, true, true) => Some("GE")
    (false, false, true) => Some("EQ")
    _ => None
  }
}

///|
/// Split `[epoch:]version[-release]`.
fn split_evr(text : String) -> (String, String, String?) {
  let mut epoch = "0"
  let mut rest = text
  match rest.find(":") {
    Some(at) => {
      epoch = rest[0:at].to_owned()
      rest = rest[at + 1:].to_owned()
    }
    None => ()
  }
  match rest.rev_find("-") {
    Some(at) => (epoch, rest[0:at].to_owned(), Some(rest[at + 1:].to_owned()))
    None => (epoch, rest, None)
  }
}

///|
/// The `<rpm:entry .../>` lines of one kind of relation. `rpmlib(...)`
/// features are not packages and stay out, like createrepo does.
fn entries_xml(
  h : @rpm.Header,
  names_tag : Int32,
  flags_tag : Int32,
  versions_tag : Int32,
  with_pre~ : Bool,
) -> String {
  let names = h.strings(names_tag)
  let flags = h.ints(flags_tag)
  let versions = h.strings(versions_tag)
  let seen : Map[String, Bool] = Map([])
  let out = StringBuilder()
  for i, name in names {
    if name.has_prefix("rpmlib(") {
      continue
    }
    let flag = if i < flags.length() { flags[i] } else { 0 }
    let version = if i < versions.length() { versions[i] } else { "" }
    let line = StringBuilder()
    line.write_string("      <rpm:entry name=\"\{escape_xml(name)}\"")
    match flag_name(flag) {
      Some(op) if version != "" => {
        let (epoch, ver, rel) = split_evr(version)
        line.write_string(
          " flags=\"\{op}\" epoch=\"\{epoch}\" ver=\"\{escape_xml(ver)}\"",
        )
        match rel {
          Some(r) => line.write_string(" rel=\"\{escape_xml(r)}\"")
          None => ()
        }
      }
      _ => ()
    }
    if with_pre && (flag & SENSE_PRE) != 0 {
      line.write_string(" pre=\"1\"")
    }
    line.write_string("/>\n")
    let text = line.to_string()
    if !seen.contains(text) {
      seen[text] = true
      out.write_string(text)
    }
  }
  out.to_string()
}

///|
fn relation_block(tag : String, body : String) -> String {
  if body == "" {
    ""
  } else {
    "    <rpm:\{tag}>\n\{body}    </rpm:\{tag}>\n"
  }
}

///|
/// Files that createrepo lists in `primary.xml` (the rest is only in
/// `filelists.xml`): configuration and executables.
fn is_primary_path(path : String) -> Bool {
  path.has_prefix("/etc/") ||
  path.has_prefix("/usr/lib/sendmail") ||
  path.has_prefix("/bin/") ||
  path.has_prefix("/sbin/") ||
  path.has_prefix("/usr/bin/") ||
  path.has_prefix("/usr/sbin/")
}

///|
fn file_line(file : @rpm.RpmFile) -> String {
  let kind = if (file.mode & 0o170000) == 0o040000 {
    " type=\"dir\""
  } else if (file.flags & 64) != 0 {
    " type=\"ghost\""
  } else {
    ""
  }
  "<file\{kind}>\{escape_xml(file.path)}</file>"
}

///|
/// What the three metadata files say about one rpm.
priv struct RpmEntry {
  primary : String
  filelist : String
  other : String
}

///|
fn describe_rpm(
  file : PackageFile,
  timestamp : Int64,
) -> RpmEntry raise RepoError {
  let pkg = @rpm.read(file.data) catch {
    err => raise RepoError::Invalid(file=file.name, message="\{err}")
  }
  let files = pkg.files() catch {
    err => raise RepoError::Invalid(file=file.name, message="\{err}")
  }
  let h = pkg.header
  let name = first_string(h, 1000)
  let version = first_string(h, 1001)
  let release = first_string(h, 1002)
  let arch = first_string(h, 1022)
  if name == "" || version == "" || release == "" || arch == "" {
    raise RepoError::Invalid(
      file=file.name,
      message="the header has no name, version, release or architecture",
    )
  }
  let epoch = match h.ints(1003) {
    [e, ..] => e
    [] => 0
  }
  let pkgid = sha256_hex(file.data)
  let header_end = file.data.length() - pkg.payload.length()
  let header_start = header_end - pkg.header_bytes.length()
  let installed = if number(h, 5009) > 0L {
    number(h, 5009)
  } else {
    number(h, 1009)
  }
  let archive = if number(pkg.signature, 271) > 0L {
    number(pkg.signature, 271)
  } else {
    number(pkg.signature, 1007)
  }
  let evr = "epoch=\"\{epoch}\" ver=\"\{escape_xml(version)}\" rel=\"\{escape_xml(release)}\""
  let primary = StringBuilder()
  primary.write_string("<package type=\"rpm\">\n")
  primary.write_string("  <name>\{escape_xml(name)}</name>\n")
  primary.write_string("  <arch>\{escape_xml(arch)}</arch>\n")
  primary.write_string("  <version \{evr}/>\n")
  primary.write_string(
    "  <checksum type=\"sha256\" pkgid=\"YES\">\{pkgid}</checksum>\n",
  )
  primary.write_string(
    "  <summary>\{escape_xml(first_string(h, 1004))}</summary>\n",
  )
  primary.write_string(
    "  <description>\{escape_xml(first_string(h, 1005))}</description>\n",
  )
  primary.write_string(
    "  <packager>\{escape_xml(first_string(h, 1015))}</packager>\n",
  )
  primary.write_string("  <url>\{escape_xml(first_string(h, 1020))}</url>\n")
  primary.write_string(
    "  <time file=\"\{timestamp}\" build=\"\{number(h, 1006)}\"/>\n",
  )
  primary.write_string(
    "  <size package=\"\{file.data.length()}\" installed=\"\{installed}\" archive=\"\{archive}\"/>\n",
  )
  primary.write_string("  <location href=\"\{escape_xml(file.name)}\"/>\n")
  primary.write_string("  <format>\n")
  primary.write_string(
    "    <rpm:license>\{escape_xml(first_string(h, 1014))}</rpm:license>\n",
  )
  primary.write_string(
    "    <rpm:vendor>\{escape_xml(first_string(h, 1011))}</rpm:vendor>\n",
  )
  primary.write_string(
    "    <rpm:group>\{escape_xml(first_string(h, 1016))}</rpm:group>\n",
  )
  primary.write_string(
    "    <rpm:buildhost>\{escape_xml(first_string(h, 1007))}</rpm:buildhost>\n",
  )
  primary.write_string(
    "    <rpm:sourcerpm>\{escape_xml(first_string(h, 1044))}</rpm:sourcerpm>\n",
  )
  primary.write_string(
    "    <rpm:header-range start=\"\{header_start}\" end=\"\{header_end}\"/>\n",
  )
  primary.write_string(
    relation_block("provides", entries_xml(h, 1047, 1112, 1113, with_pre=false)),
  )
  primary.write_string(
    relation_block("requires", entries_xml(h, 1049, 1048, 1050, with_pre=true)),
  )
  primary.write_string(
    relation_block(
      "conflicts",
      entries_xml(h, 1054, 1053, 1055, with_pre=false),
    ),
  )
  primary.write_string(
    relation_block(
      "obsoletes",
      entries_xml(h, 1090, 1114, 1115, with_pre=false),
    ),
  )
  primary.write_string(
    relation_block("suggests", entries_xml(h, 5049, 5051, 5050, with_pre=false)),
  )
  primary.write_string(
    relation_block(
      "recommends",
      entries_xml(h, 5046, 5048, 5047, with_pre=false),
    ),
  )
  for f in files {
    if is_primary_path(f.path) {
      primary.write_string("    \{file_line(f)}\n")
    }
  }
  primary.write_string("  </format>\n</package>\n")
  let filelist = StringBuilder()
  filelist.write_string(
    "<package pkgid=\"\{pkgid}\" name=\"\{escape_xml(name)}\" arch=\"\{escape_xml(arch)}\">\n",
  )
  filelist.write_string("  <version \{evr}/>\n")
  for f in files {
    filelist.write_string("  \{file_line(f)}\n")
  }
  filelist.write_string("</package>\n")
  let other = StringBuilder()
  other.write_string(
    "<package pkgid=\"\{pkgid}\" name=\"\{escape_xml(name)}\" arch=\"\{escape_xml(arch)}\">\n  <version \{evr}/>\n",
  )
  // createrepo keeps the ten newest changelog entries, oldest first.
  let times = h.ints(1080)
  let authors = h.strings(1081)
  let texts = h.strings(1082)
  let count = if times.length() < authors.length() {
    times.length()
  } else {
    authors.length()
  }
  // Header order varies between builders, so sort by time (stable).
  let order : Array[Int32] = Array::makei(count, i => i)
  order.sort_by((x, y) => {
    if times[x] < times[y] {
      -1
    } else if times[x] > times[y] {
      1
    } else {
      x - y
    }
  })
  let first = if count > 10 { count - 10 } else { 0 }
  for k in first..<count {
    let i = order[k]
    let text = if i < texts.length() { texts[i] } else { "" }
    other.write_string(
      "  <changelog author=\"\{escape_xml(authors[i])}\" date=\"\{times[i]}\">\{escape_xml(text)}</changelog>\n",
    )
  }
  other.write_string("</package>\n")
  {
    primary: primary.to_string(),
    filelist: filelist.to_string(),
    other: other.to_string(),
  }
}

///|
fn data_block(
  kind : String,
  xml : Bytes,
  packed : Bytes,
  timestamp : Int64,
) -> (String, String, String) {
  let packed_sum = sha256_hex(packed)
  let location = "repodata/\{packed_sum}-\{kind}.xml.gz"
  let block = "  <data type=\"\{kind}\">\n    <checksum type=\"sha256\">\{packed_sum}</checksum>\n    <open-checksum type=\"sha256\">\{sha256_hex(xml)}</open-checksum>\n    <location href=\"\{location}\"/>\n    <timestamp>\{timestamp}</timestamp>\n    <size>\{packed.length()}</size>\n    <open-size>\{xml.length()}</open-size>\n  </data>\n"
  (location, block, packed_sum)
}

///|
/// The metadata files of a dnf/yum repository for the given rpms, laid out
/// like createrepo's output: `repodata/repomd.xml` plus gzip-compressed
/// `primary`, `filelists` and `other` files named by their checksum.
///
/// The rpms are expected in the directory that holds `repodata/` (their
/// `location` is the bare file name). `timestamp` is used for the revision
/// and every timestamp, so the result is reproducible. Nothing is signed;
/// use `gpgcheck=0` in the `.repo` file or sign `repomd.xml` yourself.
pub fn yum_index(
  rpms : Array[PackageFile],
  timestamp~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let files = sorted_by_name(rpms)
  check_unique(files)
  let entries : Array[RpmEntry] = []
  for file in files {
    check_name(file, ".rpm")
    entries.push(describe_rpm(file, timestamp))
  }
  let ns = "xmlns:rpm=\"http://linux.duke.edu/metadata/rpm\""
  let primary = StringBuilder()
  primary.write_string(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<metadata xmlns=\"http://linux.duke.edu/metadata/common\" \{ns} packages=\"\{entries.length()}\">\n",
  )
  let filelists = StringBuilder()
  filelists.write_string(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<filelists xmlns=\"http://linux.duke.edu/metadata/filelists\" packages=\"\{entries.length()}\">\n",
  )
  let other = StringBuilder()
  other.write_string(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<otherdata xmlns=\"http://linux.duke.edu/metadata/other\" packages=\"\{entries.length()}\">\n",
  )
  for e in entries {
    primary.write_string(e.primary)
    filelists.write_string(e.filelist)
    other.write_string(e.other)
  }
  primary.write_string("</metadata>\n")
  filelists.write_string("</filelists>\n")
  other.write_string("</otherdata>\n")
  let result : Array[(String, Bytes)] = []
  let repomd = StringBuilder()
  repomd.write_string(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<repomd xmlns=\"http://linux.duke.edu/metadata/repo\" \{ns}>\n  <revision>\{timestamp}</revision>\n",
  )
  for
    part in [
      ("primary", primary.to_string()),
      ("filelists", filelists.to_string()),
      ("other", other.to_string()),
    ] {
    let xml = @utf8.encode(part.1)
    let packed = @compress.compress(xml, Gzip) catch {
      err => raise RepoError::Invalid(file=part.0, message="\{err}")
    }
    let (location, block, _) = data_block(part.0, xml, packed, timestamp)
    repomd.write_string(block)
    result.push((location, packed))
  }
  repomd.write_string("</repomd>\n")
  result.push(("repodata/repomd.xml", @utf8.encode(repomd.to_string())))
  result
}

///|
/// The build time recorded in an rpm (seconds since the epoch).
pub fn rpm_time(file : PackageFile) -> Int64 raise RepoError {
  let pkg = @rpm.read(file.data) catch {
    err => raise RepoError::Invalid(file=file.name, message="\{err}")
  }
  number(pkg.header, 1006)
}
