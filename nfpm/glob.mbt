///|
/// What the converter may ask of the machine it runs on. A browser page has
/// none of these (`read_file` and `list_dir` return `None`), the command line
/// uses the file system.
pub(all) struct Host {
  /// An environment variable, `None` when it is not set.
  getenv : (String) -> String?
  /// The content of a file, `None` when it cannot be read.
  read_file : (String) -> Bytes?
  /// The names in a directory, `None` when the path is not a directory.
  list_dir : (String) -> Array[String]?
}

///|
/// A host with an empty environment and no files.
pub fn Host::empty() -> Host {
  { getenv: _ => None, read_file: _ => None, list_dir: _ => None, }
}

///|
/// Compare two texts by their characters, left to right (the built-in
/// ordering of strings looks at the length first).
fn text_compare(a : String, b : String) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}

///|
fn has_glob_chars(text : String) -> Bool {
  for c in text {
    if c == '*' || c == '?' || c == '[' || c == '{' {
      return true
    }
  }
  false
}

///|
/// `a/b/` is `a/b`, `a/b/c` is `a/b`, `a` is `.` (Go's `filepath.Dir`).
fn go_dir(path : String) -> String {
  let mut end = path.length()
  while end > 0 && path[end - 1] != '/' {
    end -= 1
  }
  while end > 1 && path[end - 1] == '/' {
    end -= 1
  }
  if end == 0 {
    return "."
  }
  if end == 1 && path[0] == '/' {
    return "/"
  }
  path[0:end].to_owned()
}

///|
fn base_name(path : String) -> String {
  let mut end = path.length()
  while end > 0 && path[end - 1] == '/' {
    end -= 1
  }
  let mut start = end
  while start > 0 && path[start - 1] != '/' {
    start -= 1
  }
  path[start:end].to_owned()
}

///|
/// `a` and `b` joined by one slash, without `./` noise.
fn join(a : String, b : String) -> String {
  if a == "" || a == "." {
    return b
  }
  if b == "" || b == "." {
    return a
  }
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
/// Remove a leading `./` and doubled slashes: the form in which paths are
/// compared and joined.
fn clean_path(path : String) -> String {
  let parts : Array[String] = []
  for part in path.split("/") {
    let part = part.to_owned()
    if part == "" || part == "." {
      continue
    }
    parts.push(part)
  }
  let joined = parts.join("/")
  if path.has_prefix("/") {
    "/" + joined
  } else if joined == "" {
    "."
  } else {
    joined
  }
}

///|
/// Every path below `dir`, relative to it, directories and files, in name
/// order. Stops at 100000 entries so that a pattern such as `/**` cannot run
/// away.
fn walk(
  host : Host,
  dir : String,
  out : Array[String],
  prefix : String,
) -> Unit {
  if out.length() > 100000 {
    return
  }
  match (host.list_dir)(join(dir, prefix)) {
    None => ()
    Some(names) => {
      let sorted = names.copy()
      sorted.sort_by(text_compare)
      for name in sorted {
        let rel = join(prefix, name)
        out.push(rel)
        walk(host, dir, out, rel)
      }
    }
  }
}

///|
/// Match one path (`/` separated) against a pattern with `*` (anything but
/// `/`), `**` (anything, `/` included; as in nFPM's glob library `a/**/b`
/// needs at least one directory between `a` and `b`), `?` (one character
/// but `/`) and `[abc]`, `[a-z]`, `[!a]` classes.
fn glob_match(pattern : String, text : String) -> Bool {
  glob_at(pattern, 0, text, 0)
}

///|
fn glob_at(p : String, pi : Int32, t : String, ti : Int32) -> Bool {
  let mut pi = pi
  let mut ti = ti
  while pi < p.length() {
    let c = p[pi]
    if c == '*' {
      let double = pi + 1 < p.length() && p[pi + 1] == '*'
      let next = if double { pi + 2 } else { pi + 1 }
      let mut k = ti
      while true {
        if glob_at(p, next, t, k) {
          return true
        }
        if k >= t.length() {
          break
        }
        if !double && t[k] == '/' {
          break
        }
        k += 1
      }
      return false
    } else if c == '?' {
      if ti >= t.length() || t[ti] == '/' {
        return false
      }
      pi += 1
      ti += 1
    } else if c == '[' {
      if ti >= t.length() || t[ti] == '/' {
        return false
      }
      let mut j = pi + 1
      let negate = j < p.length() && (p[j] == '!' || p[j] == '^')
      if negate {
        j += 1
      }
      let mut matched = false
      let mut first = true
      while j < p.length() && (p[j] != ']' || first) {
        first = false
        let lo = p[j]
        if j + 2 < p.length() && p[j + 1] == '-' && p[j + 2] != ']' {
          let hi = p[j + 2]
          if t[ti] >= lo && t[ti] <= hi {
            matched = true
          }
          j += 3
        } else {
          if t[ti] == lo {
            matched = true
          }
          j += 1
        }
      }
      if j >= p.length() || matched == negate {
        return false
      }
      pi = j + 1
      ti += 1
    } else {
      if ti >= t.length() || t[ti] != c {
        return false
      }
      pi += 1
      ti += 1
    }
  }
  ti == t.length()
}

///|
/// Longest common prefix of the texts, character by character.
fn longest_common_prefix(items : Array[String]) -> String {
  if items.length() == 0 {
    return ""
  }
  let mut lcp = items[0]
  for item in items {
    let n = if lcp.length() < item.length() {
      lcp.length()
    } else {
      item.length()
    }
    let mut k = 0
    while k < n && lcp[k] == item[k] {
      k += 1
    }
    lcp = lcp[0:k].to_owned()
  }
  lcp
}

///|
/// The files a `src` pattern stands for and where each goes, the way
/// nFPM's `glob.Glob` decides it (github.com/goreleaser/nfpm, MIT):
///
/// * the pattern is matched against everything below its longest part
///   without special characters; a matched directory brings everything in it;
/// * with a `dst` that ends in `/` every file goes directly into that
///   directory; otherwise a file goes to `dst` plus its path relative to the
///   directory the pattern starts in (the parent of the longest common prefix
///   of all matches when the pattern has special characters, the pattern
///   itself when it is a plain path).
///
/// Returns `(source path, destination path)` pairs, files only.
fn glob_files(
  host : Host,
  pattern : String,
  dst : String,
  quote : Bool,
) -> Array[(String, String)] raise NfpmError {
  let literal = quote || !has_glob_chars(pattern)
  let cleaned = clean_path(pattern)
  let matches : Array[String] = []
  if literal {
    // A plain path: the file itself, or everything in the directory.
    match (host.list_dir)(cleaned) {
      Some(_) => {
        matches.push(cleaned)
        let inner : Array[String] = []
        walk(host, cleaned, inner, "")
        for rel in inner {
          matches.push(join(cleaned, rel))
        }
      }
      None => if (host.read_file)(cleaned) is Some(_) { matches.push(cleaned) }
    }
  } else {
    // Walk from the longest leading part of the pattern that has no
    // special characters.
    let parts = cleaned.split("/").map(p => p.to_owned()).collect()
    let fixed : Array[String] = []
    for part in parts {
      if has_glob_chars(part) {
        break
      }
      fixed.push(part)
    }
    let root = if cleaned.has_prefix("/") {
      "/" + fixed.filter(p => p != "").join("/")
    } else if fixed.length() == 0 {
      "."
    } else {
      fixed.join("/")
    }
    let below : Array[String] = []
    walk(host, root, below, "")
    let hit : Map[String, Bool] = Map([])
    for rel in below {
      let full = join(root, rel)
      if glob_match(cleaned, full) {
        hit[full] = true
      }
    }
    // A matched directory includes its contents.
    let all : Array[String] = []
    for rel in below {
      let full = join(root, rel)
      let mut included = hit.contains(full)
      if !included {
        for key, _ in hit {
          if full.has_prefix(key + "/") {
            included = true
            break
          }
        }
      }
      if included {
        all.push(full)
      }
    }
    for item in all {
      matches.push(item)
    }
  }
  if matches.length() == 0 {
    raise Invalid("glob failed: \{pattern}: no matching files")
  }
  let mut prefix = cleaned
  if !literal ||
    !((host.list_dir)(cleaned) is Some(_) ||
    (host.read_file)(cleaned) is Some(_)) {
    prefix = go_dir(longest_common_prefix(matches))
  }
  let result : Array[(String, String)] = []
  for source in matches {
    // Only files.
    if (host.list_dir)(source) is Some(_) {
      continue
    }
    if dst.has_suffix("/") {
      result.push((source, join(dst, base_name(source))))
      continue
    }
    let relative = if source == prefix {
      "."
    } else if source.has_prefix(prefix + "/") {
      source[prefix.length() + 1:].to_owned()
    } else {
      base_name(source)
    }
    result.push((source, clean_path(join(dst, relative))))
  }
  result
}

///|
/// Everything in the directory `source`: sub directories (relative path, then
/// `true`) and files (relative path, then `false`), in name order.
fn tree_entries(host : Host, source : String) -> Array[(String, Bool)] {
  let inner : Array[String] = []
  walk(host, clean_path(source), inner, "")
  let result : Array[(String, Bool)] = []
  for rel in inner {
    result.push(
      (rel, (host.list_dir)(join(clean_path(source), rel)) is Some(_)),
    )
  }
  result
}
