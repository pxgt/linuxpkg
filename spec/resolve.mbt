///|
/// The files `Config::resolve` needs, in order of first use and without
/// duplicates: every `src` of a file item, then the maintainer scripts. The
/// caller reads them (relative to the config file, usually) and passes the
/// bytes back keyed by the same strings.
pub fn Config::sources(self : Config) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  let result : Array[String] = []
  let add = (path : String) => {
    if !seen.contains(path) {
      seen[path] = true
      result.push(path)
    }
  }
  for content in self.contents {
    match (content.kind, content.src) {
      (File | ConfigFile, Some(path)) => add(path)
      _ => ()
    }
  }
  for
    script in [
      self.scripts.pre_install,
      self.scripts.post_install,
      self.scripts.pre_remove,
      self.scripts.post_remove,
    ] {
    match script {
      Some(path) => add(path)
      None => ()
    }
  }
  result
}

///|
fn text_of(
  files : Map[String, Bytes],
  path : String?,
  field : String,
) -> String? raise SpecError {
  match path {
    None => None
    Some(p) =>
      match files.get(p) {
        None => raise invalid(field, "file \"\{p}\" was not provided")
        Some(bytes) =>
          Some(
            @utf8.decode(bytes) catch {
              _ => raise invalid(field, "file \"\{p}\" is not valid UTF-8 text")
            },
          )
      }
  }
}

///|
/// Combine a config with the content of the files it names into a validated
/// `PackageSpec`.
///
/// The package modification time is the config's `mtime` when set and
/// `default_mtime` otherwise; callers pass `SOURCE_DATE_EPOCH` here to make
/// builds reproducible.
pub fn Config::resolve(
  self : Config,
  files : Map[String, Bytes],
  default_mtime~ : Int64 = 0L,
) -> PackageSpec raise SpecError {
  let entries : Array[Entry] = []
  for i, content in self.contents {
    let field = "contents[\{i}]"
    let owner = match content.owner {
      Some(name) => name
      None => "root"
    }
    let group = match content.group {
      Some(name) => name
      None => "root"
    }
    let entry = match content.kind {
      File | ConfigFile => {
        let path = content.src.unwrap()
        let data = match files.get(path) {
          Some(bytes) => bytes
          None =>
            raise invalid("\{field}.src", "file \"\{path}\" was not provided")
        }
        let config = content.kind is ConfigFile
        match content.mode {
          Some(mode) =>
            Entry::file(
              content.dst,
              data,
              mode~,
              owner~,
              group~,
              mtime?=content.mtime,
              config~,
            )
          None =>
            Entry::file(
              content.dst,
              data,
              owner~,
              group~,
              mtime?=content.mtime,
              config~,
            )
        }
      }
      Dir =>
        match content.mode {
          Some(mode) =>
            Entry::dir(content.dst, mode~, owner~, group~, mtime?=content.mtime)
          None => Entry::dir(content.dst, owner~, group~, mtime?=content.mtime)
        }
      Symlink =>
        Entry::symlink(
          content.dst,
          content.src.unwrap(),
          owner~,
          group~,
          mtime?=content.mtime,
        )
    }
    entries.push(entry)
  }
  let scripts : Scripts = {
    pre_install: text_of(files, self.scripts.pre_install, "scripts.preinstall"),
    post_install: text_of(
      files,
      self.scripts.post_install,
      "scripts.postinstall",
    ),
    pre_remove: text_of(files, self.scripts.pre_remove, "scripts.preremove"),
    post_remove: text_of(files, self.scripts.post_remove, "scripts.postremove"),
  }
  let spec = PackageSpec::new(
    name=self.name,
    version=self.version,
    release=self.release,
    epoch=self.epoch,
    arch=self.arch,
    maintainer=self.maintainer,
    description=self.description,
    homepage?=self.homepage,
    license?=self.license,
    vendor?=self.vendor,
    section=self.section,
    priority=self.priority,
    depends=self.depends,
    recommends=self.recommends,
    suggests=self.suggests,
    conflicts=self.conflicts,
    replaces=self.replaces,
    provides=self.provides,
    entries~,
    scripts~,
    mtime=match self.mtime {
      Some(t) => t
      None => default_mtime
    },
  )
  spec.validate()
  self.check_elf_arch(files)
  spec
}
