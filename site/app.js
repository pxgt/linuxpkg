"use strict";
// linuxpkg web page. The package logic is the MoonBit library compiled to JavaScript
// (linuxpkg-web.js); this file only reads files, calls it and draws the answers.
// Nothing is sent anywhere: there are no network requests besides loading the page itself.

const T = {
  en: {
    nav_try: "Try it", nav_build: "Build", nav_install: "Install", nav_verified: "Verified", nav_docs: "Docs",
    hero_title: "Build, sign and publish Linux packages — in pure MoonBit",
    hero_lead: "One JSON file becomes a deb, rpm, Arch and Alpine package. Sign them, make apt, dnf, pacman and apk repositories, and check packages from any distribution. No dpkg, no rpmbuild, no root; it runs on Windows, macOS, Linux and in this page.",
    btn_try: "Try it online", btn_install: "Install",
    privacy: "Everything happens in your browser. Files you drop here are never uploaded.",
    try_title: "Inspect and verify a package",
    try_lead: "Drop a .deb, .rpm, .apk or .pkg.tar.* file. You get the metadata, the file list, a check of every checksum and the signature state.",
    drop_text: "Drop packages here, or click to choose",
    samples: "Or load a sample built right now by linuxpkg:",
    keyring_sum: "Check a signature (optional): paste a public key",
    build_title: "Build a package",
    build_lead: "Edit the configuration, add your files, and get all four formats. The bytes are identical to what the command line writes for the same input.",
    config_label: "linuxpkg.json", files_label: "Files (the config names them under \"src\")", add_files: "Add files…",
    compression: "Compression", formats: "Formats", do_build: "Build",
    install_title: "Install",
    install_cli: "The command line is one static binary (Linux x86_64 and aarch64) or moonx Xpeng/linuxpkg/cmd/main anywhere MoonBit runs; as a library: moon add Xpeng/linuxpkg.",
    install_repos_soon: "Signed apt, dnf, pacman and apk repositories of linuxpkg itself are published with the next release; this section will list the commands.",
    verified_title: "Checked by the real tools",
    verified_lead: "Every claim is run in CI against the official tools, in the distributions' containers.",
    row_pkg: "package", row_repo: "repository", row_sign: "signature", ci_link: "See the latest CI run",
    docs_title: "Documentation", doc_config: "Configuration reference", doc_signing: "Signing", doc_repo: "Repositories",
    doc_formats: "Package formats and differences", doc_verification: "How everything is verified",
    footer_local: "No cookies, no tracking, no external requests.",
    r_name: "Name", r_version: "Version", r_arch: "Architecture", r_summary: "Summary", r_maintainer: "Maintainer",
    r_license: "License", r_homepage: "Homepage", r_compression: "Compression", r_size: "Installed size",
    r_depends: "Depends", r_files: "Files", r_path: "Path", r_type: "Type", r_mode: "Mode", r_owner: "Owner", r_bytes: "Bytes",
    r_checks_ok: "all checksums match", r_checks_bad: "problems found", r_checked: "checksums verified",
    sig_unsigned: "unsigned", sig_signed: "signed by key", sig_good: "signature OK, key", sig_bad: "bad signature",
    sig_na: "signed through the repository (or a .sig file)", sig_unchecked: "not checked: no key given",
    built_title: "Built", built_note: "Same bytes as `linuxpkg build` on the command line.", inspect_it: "inspect",
    skipped: "skipped", error: "Error", loaderror: "linuxpkg-web.js could not be loaded; the page cannot run the library.",
    pick_files: "Choose the files named in the configuration, then build.", missing_file: "Add this file: ",
  },
  zh: {
    nav_try: "在线试用", nav_build: "打包", nav_install: "安装", nav_verified: "验证", nav_docs: "文档",
    hero_title: "用纯 MoonBit 构建、签名、发布 Linux 软件包",
    hero_lead: "一份 JSON 配置，生成 deb、rpm、Arch、Alpine 四种包。还能签名、生成 apt / dnf / pacman / apk 软件源，并检查任何发行版的包。不需要 dpkg、rpmbuild 和 root，在 Windows、macOS、Linux 和这个网页里都能跑。",
    btn_try: "在线试用", btn_install: "安装",
    privacy: "全部在你的浏览器里完成，你放进来的文件不会被上传。",
    try_title: "检查并校验软件包",
    try_lead: "拖入 .deb、.rpm、.apk 或 .pkg.tar.* 文件，显示元数据、文件列表、逐项校验和以及签名情况。",
    drop_text: "把软件包拖到这里，或点击选择",
    samples: "或者加载一个刚刚由 linuxpkg 现场打出来的样例：",
    keyring_sum: "检查签名（可选）：粘贴公钥",
    build_title: "打一个包",
    build_lead: "改配置、加文件，一次得到四种格式。同样的输入，字节和命令行完全一致。",
    config_label: "linuxpkg.json", files_label: "文件（配置里用 \"src\" 指名）", add_files: "添加文件…",
    compression: "压缩", formats: "格式", do_build: "开始打包",
    install_title: "安装",
    install_cli: "命令行是一个静态二进制（Linux x86_64 和 aarch64），或在任何能跑 MoonBit 的地方用 moonx Xpeng/linuxpkg/cmd/main；作为库：moon add Xpeng/linuxpkg。",
    install_repos_soon: "linuxpkg 自己的带签名 apt、dnf、pacman、apk 软件源会随下一个版本发布，这里届时会列出安装命令。",
    verified_title: "由真实工具验证",
    verified_lead: "每一条说法都在 CI 里用官方工具、在各发行版的容器中实际运行。",
    row_pkg: "软件包", row_repo: "软件源", row_sign: "签名", ci_link: "查看最近一次 CI",
    docs_title: "文档", doc_config: "配置参考", doc_signing: "签名", doc_repo: "软件源",
    doc_formats: "包格式与差异", doc_verification: "如何验证一切",
    footer_local: "没有 Cookie、没有统计、没有外部请求。",
    r_name: "名称", r_version: "版本", r_arch: "架构", r_summary: "摘要", r_maintainer: "维护者",
    r_license: "许可证", r_homepage: "主页", r_compression: "压缩", r_size: "安装后大小",
    r_depends: "依赖", r_files: "文件", r_path: "路径", r_type: "类型", r_mode: "权限", r_owner: "属主", r_bytes: "字节",
    r_checks_ok: "所有校验和一致", r_checks_bad: "发现问题", r_checked: "项校验和已核对",
    sig_unsigned: "未签名", sig_signed: "已签名，密钥", sig_good: "签名有效，密钥", sig_bad: "签名无效",
    sig_na: "通过软件源（或 .sig 文件）签名", sig_unchecked: "未校验：没有提供公钥",
    built_title: "已生成", built_note: "和命令行 `linuxpkg build` 的字节相同。", inspect_it: "检查",
    skipped: "已跳过", error: "出错", loaderror: "无法加载 linuxpkg-web.js，本页不能运行。",
    pick_files: "请选择配置里列出的文件，然后打包。", missing_file: "请添加文件：",
  },
};

let lang = "en";
try {
  const saved = localStorage.getItem("lp-lang");
  if (saved === "zh" || saved === "en") lang = saved;
  else if ((navigator.language || "").toLowerCase().startsWith("zh")) lang = "zh";
} catch (_) { /* storage may be blocked */ }

function t(key) { return (T[lang] && T[lang][key]) || T.en[key] || key; }

function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") node.className = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const kid of kids) node.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return node;
}

function applyLang() {
  document.documentElement.lang = lang;
  for (const node of document.querySelectorAll("[data-i18n]")) {
    const key = node.getAttribute("data-i18n");
    node.textContent = t(key);
  }
  document.getElementById("lang").textContent = lang === "en" ? "中文" : "English";
  renderAll();
}

// ---- reading files
function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  return btoa(binary);
}
function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
async function readFile(file) { return toBase64(await file.arrayBuffer()); }

// ---- inspect panel
const entries = []; // {name, data (base64)}

function sizeText(n) { return n < 1024 ? n + " B" : n < 1048576 ? (n / 1024).toFixed(1) + " KiB" : (n / 1048576).toFixed(1) + " MiB"; }

function signatureText(sig) {
  switch (sig.state) {
    case "unsigned": return [t("sig_unsigned"), ""];
    case "signed": return [t("sig_signed") + " " + sig.key + " (" + t("sig_unchecked") + ")", ""];
    case "good": return [t("sig_good") + " " + sig.key, "ok"];
    case "bad": return [t("sig_bad") + ": " + sig.message, "bad"];
    default: return [t("sig_na"), ""];
  }
}

function drawResult(entry) {
  const box = el("div", { class: "result" });
  const keyring = document.getElementById("keyring").value;
  const info = JSON.parse(globalThis.lp_inspect(entry.name, entry.data));
  box.append(el("h3", {}, entry.name));
  if (info.error) {
    box.append(el("p", { class: "bad" }, t("error") + ": " + info.error));
    return box;
  }
  const verified = JSON.parse(globalThis.lp_verify(entry.name, entry.data, keyring));
  const r = info.report;
  const problems = verified.problems || [];
  box.append(el("p", {},
    el("span", { class: "badge" }, info.kind),
    el("span", { class: "badge " + (problems.length ? "bad" : "ok") },
      problems.length ? t("r_checks_bad") + " (" + problems.length + ")" : t("r_checks_ok") + " · " + verified.checked + " " + t("r_checked")),
  ));
  const [sigText, sigClass] = signatureText(verified.signature && keyring.trim() ? verified.signature : info.signature);
  box.append(el("p", { class: sigClass }, "✎ " + sigText));
  for (const p of problems) box.append(el("p", { class: "bad" }, p));
  const meta = el("dl", { class: "meta" });
  const add = (label, value) => { if (value !== null && value !== undefined && value !== "") { meta.append(el("dt", {}, label), el("dd", {}, value)); } };
  add(t("r_name"), r.name);
  add(t("r_version"), r.version + (r.release ? "-" + r.release : ""));
  add(t("r_arch"), r.architecture);
  add(t("r_summary"), r.summary);
  add(t("r_maintainer"), r.maintainer);
  add(t("r_license"), r.license);
  add(t("r_homepage"), r.homepage);
  add(t("r_compression"), r.compression ? Object.entries(r.compression).map(([k, v]) => k + ": " + v).join(", ") : "");
  add(t("r_size"), r.installed_size_kib !== undefined ? r.installed_size_kib + " KiB" : "");
  add(t("r_depends"), (r.depends || []).join(", "));
  box.append(meta);
  const table = el("table", {}, el("thead", {}, el("tr", {},
    el("th", {}, t("r_path")), el("th", {}, t("r_type")), el("th", {}, t("r_mode")), el("th", {}, t("r_owner")), el("th", {}, t("r_bytes")))));
  const body = el("tbody");
  for (const f of r.files || []) {
    body.append(el("tr", {},
      el("td", { class: "path" }, f.path + (f.link ? " → " + f.link : "")),
      el("td", {}, f.type), el("td", {}, f.mode), el("td", {}, f.owner + "/" + f.group),
      el("td", { class: "num" }, f.size)));
  }
  table.append(body);
  box.append(el("h4", {}, t("r_files") + " (" + (r.files || []).length + ")"), el("div", { class: "filelist" }, table));
  return box;
}

function renderResults() {
  const out = document.getElementById("results");
  out.replaceChildren(...entries.map(drawResult));
}

async function addPackages(files) {
  for (const file of files) entries.unshift({ name: file.name, data: await readFile(file) });
  renderResults();
}

// ---- samples and the build panel
const SAMPLE_SCRIPT = "#!/bin/sh\necho 'hello from linuxpkg'\n";
const SAMPLE_CONF = "greeting = hello\n";
const SAMPLE_CONFIG = {
  name: "hello", version: "1.0.0", arch: "all",
  maintainer: "You <you@example.org>", description: "Example program\nBuilt in the browser by linuxpkg.",
  license: "Apache-2.0", homepage: "https://github.com/pxgt/linuxpkg", mtime: 1700000000,
  contents: [
    { src: "hello.sh", dst: "/usr/bin/hello", mode: "0755" },
    { src: "hello.conf", dst: "/etc/hello.conf", type: "config" },
  ],
};
const textBase64 = (s) => toBase64(new TextEncoder().encode(s));

function buildPackages(config, files, formats, compression) {
  const result = JSON.parse(globalThis.lp_build(config, JSON.stringify(files), formats, compression, 0));
  return result;
}

function loadSample(kind) {
  const files = { "hello.sh": textBase64(SAMPLE_SCRIPT), "hello.conf": textBase64(SAMPLE_CONF) };
  const result = buildPackages(JSON.stringify(SAMPLE_CONFIG), files, kind, "");
  if (result.error || !result.packages.length) {
    entries.unshift({ name: "sample." + kind, data: "" });
  } else {
    const p = result.packages[0];
    entries.unshift({ name: p.name, data: p.data });
  }
  renderResults();
}

const buildFiles = new Map(); // name -> base64

function renderSrcFiles() {
  const box = document.getElementById("srcfiles");
  let needed = [];
  try {
    const cfg = JSON.parse(document.getElementById("config").value);
    for (const c of cfg.contents || []) if (c.src && (!c.type || c.type === "file" || c.type === "config")) needed.push(c.src);
    for (const s of Object.values(cfg.scripts || {})) needed.push(s);
  } catch (_) { /* the user is still typing */ }
  const names = [...new Set([...needed, ...buildFiles.keys()])];
  box.replaceChildren(...names.map((n) => el("div", { class: "item" },
    el("span", { class: buildFiles.has(n) ? "ok" : "bad" }, (buildFiles.has(n) ? "✓ " : "✗ ") + n),
    buildFiles.has(n) ? el("button", { class: "chip", type: "button", onclick: () => { buildFiles.delete(n); renderSrcFiles(); } }, "×") : "")));
  if (!names.length) box.append(el("p", {}, t("pick_files")));
}

async function addBuildFiles(files) {
  for (const f of files) buildFiles.set(f.name, await readFile(f));
  renderSrcFiles();
}

function doBuild() {
  const out = document.getElementById("built");
  out.replaceChildren();
  const files = Object.fromEntries(buildFiles);
  const result = buildPackages(document.getElementById("config").value, files,
    document.getElementById("formats").value, document.getElementById("compression").value);
  if (result.error) {
    out.append(el("p", { class: "bad" }, t("error") + ": " + result.error));
    return;
  }
  const links = el("div", { class: "downloads" });
  for (const p of result.packages) {
    const blob = new Blob([fromBase64(p.data)], { type: "application/octet-stream" });
    links.append(
      el("a", { href: URL.createObjectURL(blob), download: p.name }, "⬇ " + p.name + " (" + sizeText(blob.size) + ")"),
      el("button", { class: "chip", type: "button", onclick: () => { entries.unshift({ name: p.name, data: p.data }); renderResults(); document.getElementById("try").scrollIntoView(); } }, t("inspect_it")),
      el("br"));
  }
  out.append(el("h3", {}, t("built_title")), links, el("p", {}, t("built_note")));
  for (const s of result.skipped || []) out.append(el("p", { class: "bad" }, t("skipped") + ": " + s));
}

function renderAll() { if (globalThis.lp_inspect) { renderResults(); renderSrcFiles(); } }

// ---- wiring
function start() {
  document.getElementById("lang").addEventListener("click", () => {
    lang = lang === "en" ? "zh" : "en";
    try { localStorage.setItem("lp-lang", lang); } catch (_) { /* ignore */ }
    applyLang();
  });
  if (!globalThis.lp_inspect) {
    const bar = document.getElementById("loaderror");
    bar.hidden = false;
    bar.textContent = t("loaderror");
    applyLang();
    return;
  }
  const drop = document.getElementById("drop");
  const input = document.getElementById("file");
  drop.addEventListener("click", () => input.click());
  drop.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); input.click(); } });
  input.addEventListener("change", () => { addPackages(input.files); input.value = ""; });
  for (const ev of ["dragenter", "dragover"]) drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("over"); });
  for (const ev of ["dragleave", "drop"]) drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove("over"); });
  drop.addEventListener("drop", (e) => addPackages(e.dataTransfer.files));
  for (const b of document.querySelectorAll("[data-sample]")) b.addEventListener("click", () => loadSample(b.dataset.sample));
  document.getElementById("keyring").addEventListener("input", renderResults);

  const config = document.getElementById("config");
  config.value = JSON.stringify(SAMPLE_CONFIG, null, 2);
  config.addEventListener("input", renderSrcFiles);
  buildFiles.set("hello.sh", textBase64(SAMPLE_SCRIPT));
  buildFiles.set("hello.conf", textBase64(SAMPLE_CONF));
  const addInput = document.getElementById("addinput");
  document.getElementById("addfile").addEventListener("click", () => addInput.click());
  addInput.addEventListener("change", () => { addBuildFiles(addInput.files); addInput.value = ""; });
  document.getElementById("dobuild").addEventListener("click", doBuild);
  applyLang();
}
start();
